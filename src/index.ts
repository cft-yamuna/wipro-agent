import { readFileSync } from 'fs';
import { resolve } from 'path';
import { loadConfig } from './lib/config.js';
import { Logger } from './lib/logger.js';
import { provision } from './services/provisioning.js';
import { WsClient } from './services/websocket.js';
import { HealthMonitor } from './services/health.js';
import { CommandExecutor } from './services/commands.js';
import { KioskManager } from './services/kiosk.js';
import { registerPowerCommands } from './commands/power.js';
import { registerKioskCommands } from './commands/kiosk.js';
import { registerScreenshotCommands } from './commands/screenshot.js';
import { registerDisplayCommands } from './commands/display.js';
import { registerNetworkCommands } from './commands/network.js';
import { Updater } from './services/updater.js';
import { registerUpdateCommands } from './commands/update.js';
import { Watchdog } from './services/watchdog.js';
import { registerMaintenanceCommands } from './commands/maintenance.js';
import { LogForwarder } from './services/logForwarder.js';
import { registerRpiCommands } from './commands/rpi.js';
import { registerSerialCommands } from './commands/serial.js';
import { isRaspberryPi } from './lib/rpi.js';
import { ServiceLauncher } from './services/serviceLauncher.js';
import { StaticServer } from './services/staticServer.js';
import { PowerScheduler } from './services/powerScheduler.js';
import { SerialBridge } from './services/serialBridge.js';
import { LocalEventServer } from './services/localEvents.js';
import type { WsMessage, KioskConfig, PowerScheduleConfig, Identity } from './lib/types.js';

function getAgentVersion(): string {
  try {
    const pkg = JSON.parse(readFileSync(resolve(process.cwd(), 'package.json'), 'utf-8'));
    return pkg.version || '1.0.0';
  } catch {
    return '1.0.0';
  }
}

async function main(): Promise<void> {
  // 1. Load config
  const config = loadConfig();
  const logger = new Logger(config.logLevel, config.logFile);

  logger.info('LIGHTMAN Agent starting...');
  logger.info(`Server: ${config.serverUrl}`);
  logger.info(`Device slug: ${config.deviceSlug}`);

  // 1b. Start built-in display static server
  const displayDistPath = resolve(process.cwd(), 'public');
  const staticServer = new StaticServer(3403, displayDistPath, config.serverUrl, logger);
  staticServer.start();

  // 1c. Start local server & display services (dev mode only)
  let serviceLauncher: ServiceLauncher | null = null;
  if (config.localServices) {
    const projectRoot = resolve(process.cwd(), '..');
    serviceLauncher = new ServiceLauncher(logger, projectRoot);
    try {
      await serviceLauncher.startAll();
    } catch (err) {
      logger.error('Failed to start services:', err);
      process.exit(1);
    }
  } else {
    logger.info('Local services disabled (kiosk-only mode)');
  }

  // 2. Provision (get identity)
  // Provision with retry — never crash, just keep trying.
  // This prevents NSSM restart loops that kill Chrome (blinking screen).
  let identity;
  const MAX_PROVISION_ATTEMPTS = 999;
  for (let attempt = 1; attempt <= MAX_PROVISION_ATTEMPTS; attempt++) {
    try {
      const result = await provision(config, logger);
      identity = result.identity;
      logger.info(
        `Device ID: ${identity.deviceId} (${result.fromCache ? 'cached' : 'new'})`
      );
      break;
    } catch (err) {
      logger.error(`Provisioning attempt ${attempt} failed:`, err);
      if (attempt < MAX_PROVISION_ATTEMPTS) {
        const waitSec = Math.min(30, attempt * 5);
        logger.info(`Retrying provisioning in ${waitSec}s...`);
        await new Promise((r) => setTimeout(r, waitSec * 1000));
      } else {
        logger.error('All provisioning attempts exhausted. Exiting.');
        process.exit(1);
      }
    }
  }

  // 3. Create WebSocket client
  let commandExecutor: CommandExecutor;
  let powerScheduler: PowerScheduler;

  const wsClient = new WsClient({
    serverUrl: config.serverUrl,
    identity,
    logger,
    onMessage: (msg: WsMessage) => {
      handleServerMessage(msg, commandExecutor, logger, powerScheduler, startSerialBridge, stopSerialBridge);
    },
  });

  // 4. Start health monitor
  const healthMonitor = new HealthMonitor(
    wsClient,
    logger,
    config.healthIntervalMs,
    config.serverUrl
  );

  // 4b. Start log forwarder
  const logForwarder = new LogForwarder(wsClient, logger);
  logger.onLog((entry) => logForwarder.onLog(entry));
  logForwarder.start();

  // 5. Create command executor and register built-in commands
  commandExecutor = new CommandExecutor(wsClient, logger);

  // Register Phase 15 system management commands
  registerPowerCommands(commandExecutor.register.bind(commandExecutor), logger);
  registerDisplayCommands(commandExecutor.register.bind(commandExecutor), logger);
  registerScreenshotCommands(commandExecutor.register.bind(commandExecutor), logger);

  // Create KioskManager if kiosk config is present
  const baseKioskConfig: KioskConfig = config.kiosk || {
    browserPath: 'chromium-browser',
    defaultUrl: `${config.serverUrl.replace(/:\d+$/, ':3401')}/display`,
    extraArgs: [],
    pollIntervalMs: 10_000,
    maxCrashesInWindow: 10,
    crashWindowMs: 300_000,
  };
  // Inject credentials into the kiosk URL so Chrome auto-provisions without pairing
  const kioskUrl = new URL(baseKioskConfig.defaultUrl);
  kioskUrl.searchParams.set('deviceId', identity.deviceId);
  kioskUrl.searchParams.set('apiKey', identity.apiKey);
  const kioskConfig: KioskConfig = { ...baseKioskConfig, defaultUrl: kioskUrl.toString() };
  const kioskManager = new KioskManager(kioskConfig, logger);
  registerKioskCommands(commandExecutor.register.bind(commandExecutor), kioskManager, logger);

  // Create Watchdog (Phase 20)
  const watchdog = new Watchdog(
    kioskManager,
    wsClient,
    healthMonitor,
    logger,
    config.serverUrl,
    identity,
    undefined,
    config.kiosk?.shellMode
  );
  registerMaintenanceCommands(commandExecutor.register.bind(commandExecutor), watchdog, logger);

  // Register Phase 20 network commands
  registerNetworkCommands(commandExecutor.register.bind(commandExecutor), logger, config.serverUrl);

  // Create Updater and register OTA update commands (Phase 20)
  const updater = new Updater(logger);
  registerUpdateCommands(commandExecutor.register.bind(commandExecutor), updater, wsClient, logger);

  // Register RPi-specific commands when running on Raspberry Pi
  if (isRaspberryPi()) {
    registerRpiCommands(commandExecutor.register.bind(commandExecutor), logger);
    logger.info('Raspberry Pi detected, RPi commands registered');
  }

  // Register serial/COM port commands (works on all platforms)
  registerSerialCommands(commandExecutor.register.bind(commandExecutor), logger);

  // Local hardware event server — broadcasts directly to Chrome on this device
  const localEventServer = new LocalEventServer(config.localEventsPort || 3402, logger);
  localEventServer.start();

  // Serial bridge — reads COM port chars (* → pickup, # → hangup) and forwards to server
  let serialBridge: SerialBridge | null = null;

  /** Start or restart the serial bridge with given COM port and controllerId */
  const startSerialBridge = (comPort: string, controllerId: string, baudRate?: number) => {
    if (serialBridge) {
      logger.info(`[SERIAL] Stopping existing bridge before restart`);
      serialBridge.stop();
      serialBridge = null;
    }
    const baud = baudRate || 115200;
    logger.info(`[SERIAL] Opening ${comPort} @ ${baud} baud (controllerId: ${controllerId})`);
    serialBridge = new SerialBridge({
      wsClient,
      logger,
      port: comPort,
      baudRate: baud,
      controllerId,
      onEvent: (event) => localEventServer.broadcast({ type: 'hardware:event', payload: event }),
    });
    serialBridge.start();
    logger.info(`[SERIAL] Bridge started — waiting for hardware events on ${comPort}`);
  };

  const stopSerialBridge = () => {
    if (serialBridge) { serialBridge.stop(); serialBridge = null; }
  };

  // Register serial bridge commands
  commandExecutor.register('serial:bridge-start', async (args) => {
    const comPort = args?.comPort as string || args?.port as string;
    const controllerId = args?.controllerId as string;
    const baudRate = args?.baudRate as number;
    if (!comPort) throw new Error('comPort is required');
    if (!controllerId) throw new Error('controllerId is required');
    startSerialBridge(comPort, controllerId, baudRate);
    return { started: true, comPort, controllerId };
  });

  commandExecutor.register('serial:bridge-stop', async () => {
    if (serialBridge) {
      serialBridge.stop();
      serialBridge = null;
      return { stopped: true };
    }
    return { stopped: false, message: 'No bridge running' };
  });

  commandExecutor.register('serial:bridge-status', async () => {
    return { running: serialBridge?.isRunning() || false };
  });

  // Create PowerScheduler for local cron-based shutdown + server-pushed power commands
  const powerScheduleConfig: PowerScheduleConfig = config.powerSchedule || {
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    shutdownWarningSeconds: 60,
  };
  powerScheduler = new PowerScheduler(powerScheduleConfig, logger, wsClient);

  // Register power schedule commands (server can trigger/cancel shutdown and update schedule)
  commandExecutor.register('power:shutdown-now', async (args) => {
    const reason = (args?.reason as string) || 'admin-command';
    powerScheduler.triggerShutdown(reason);
    return { shutdownTriggered: true, reason };
  });

  commandExecutor.register('power:cancel-shutdown', async () => {
    const cancelled = powerScheduler.cancelShutdown();
    return { cancelled };
  });

  commandExecutor.register('power:update-schedule', async (args) => {
    if (args) {
      powerScheduler.updateSchedule(args as Partial<PowerScheduleConfig>);
    }
    return { updated: true };
  });

  // Register built-in commands
  commandExecutor.register('ping', async () => {
    return { pong: true, timestamp: Date.now() };
  });

  commandExecutor.register('status', async () => {
    const health = await healthMonitor.collect();
    return {
      connected: wsClient.isConnected(),
      health,
    };
  });

  commandExecutor.register('restart-agent', async () => {
    logger.warn('Restart command received, exiting (systemd will restart)...');
    // Delay to allow result to be sent
    setTimeout(() => process.exit(0), 1000);
    return { restarting: true };
  });

  // 6. Connect and start
  wsClient.connect();
  healthMonitor.start();
  watchdog.start();
  powerScheduler.start();

  // Send registration message once connected, then auto-launch kiosk
  const registerInterval = setInterval(() => {
    if (wsClient.isConnected()) {
      wsClient.send({
        type: 'agent:register',
        payload: { agentVersion: getAgentVersion() },
        timestamp: Date.now(),
      });
      clearInterval(registerInterval);

      // Auto-launch kiosk browser if kiosk config is present
      if (config.kiosk) {
        if (config.kiosk.shellMode) {
          // Shell mode: Chrome is launched by the Windows shell (lightman-shell.bat).
          // We just write the URL sidecar so the shell knows which URL to open.
          logger.info('Shell mode: skipping Chrome launch (managed by Windows shell)');
          kioskManager.launch().catch((err) => {
            logger.error('Failed to update kiosk URL sidecar:', err);
          });
        } else {
          logger.info('Auto-launching kiosk browser...');
          kioskManager.launch().catch((err) => {
            logger.error('Failed to auto-launch kiosk:', err);
          });
        }
      }

      // Fetch device config and auto-start serial bridge if com_port is configured
      fetchDeviceConfig(config.serverUrl, identity, logger).then((deviceCfg) => {
        if (deviceCfg && deviceCfg.comPort) {
          const comPort = deviceCfg.comPort;
          const controllerId = deviceCfg.controllerId || comPort;
          const bridgeBaud = deviceCfg.baudRate || 115200;
          logger.info(`[SERIAL] com_port found: ${comPort} | controllerId: ${controllerId} | baud: ${bridgeBaud}`);
          logger.info(`[SERIAL] Starting serial bridge — listening on ${comPort}...`);
          startSerialBridge(comPort, controllerId, bridgeBaud);
        } else {
          logger.info('[SERIAL] No com_port configured on this device — serial bridge not started');
        }
      }).catch((err) => {
        logger.warn('[SERIAL] Could not fetch device config:', err);
      });
    }
  }, 1000);

  // 7. Graceful shutdown
  const shutdown = async (signal: string): Promise<void> => {
    logger.info(`${signal} received. Shutting down...`);
    clearInterval(registerInterval);

    // Wait for updater to finish if it's busy (max 60s)
    if (updater.isBusy()) {
      logger.warn('Updater is busy, waiting for it to finish before exit...');
      const maxWaitMs = 60_000;
      const pollMs = 500;
      let waited = 0;
      while (updater.isBusy() && waited < maxWaitMs) {
        await new Promise((r) => setTimeout(r, pollMs));
        waited += pollMs;
      }
      if (updater.isBusy()) {
        logger.error('Updater still busy after 60s, forcing shutdown');
      } else {
        logger.info('Updater finished, proceeding with shutdown');
      }
    }

    logForwarder.stop();
    powerScheduler.stop();
    if (serialBridge) serialBridge.stop();
    watchdog.stop();
    healthMonitor.stop();
    kioskManager.destroy();
    wsClient.close();
    staticServer.stop();
    serviceLauncher?.stopAll();
    logger.info('Agent stopped.');
    process.exit(0);
  };

  process.on('SIGTERM', () => { shutdown('SIGTERM'); });
  process.on('SIGINT', () => { shutdown('SIGINT'); });

  process.on('unhandledRejection', (reason) => {
    logger.error('Unhandled rejection:', reason);
  });

  process.on('uncaughtException', (err) => {
    logger.error('Uncaught exception:', err);
    process.exit(1);
  });

  logger.info('LIGHTMAN Agent running.');
}

function handleServerMessage(
  msg: WsMessage,
  commandExecutor: CommandExecutor,
  logger: Logger,
  powerScheduler?: PowerScheduler,
  startSerialBridge?: (comPort: string, controllerId: string, baudRate?: number) => void,
  stopSerialBridge?: () => void
): void {
  switch (msg.type) {
    case 'connected':
      logger.info('Server acknowledged connection');
      break;
    case 'command':
      commandExecutor.handleCommand(msg);
      break;
    case 'agent:config':
      if (msg.payload) {
        const logLevel = msg.payload.log_level as string | undefined;
        if (logLevel && ['debug', 'info', 'warn', 'error'].includes(logLevel)) {
          logger.setLevel(logLevel as 'debug' | 'info' | 'warn' | 'error');
          logger.info(`Log level changed to: ${logLevel}`);
        }

        // Admin pushed updated com_port via save
        const comPort = msg.payload.com_port as string | undefined;
        if (comPort && startSerialBridge) {
          const controllerId = (msg.payload.controllerId as string) || comPort;
          logger.info(`[SERIAL] Admin updated com_port → ${comPort} | Restarting serial bridge...`);
          startSerialBridge(comPort, controllerId);
          logger.info(`[SERIAL] Serial bridge now listening on ${comPort}`);
        } else if (comPort === '' && stopSerialBridge) {
          logger.info('[SERIAL] Admin cleared com_port — stopping serial bridge');
          stopSerialBridge();
        }
      }
      break;
    case 'agent:power-schedule':
      // Server pushes updated power schedule
      if (msg.payload && powerScheduler) {
        logger.info('Received power schedule update from server');
        powerScheduler.updateSchedule(msg.payload as Partial<PowerScheduleConfig>);
      }
      break;
    default:
      logger.debug(`Unknown message type: ${msg.type}`, msg);
  }
}

/**
 * Fetch the device's own config from the server (uses API-key auth).
 * Returns com_port, controllerId and baudRate from the device config + app config.
 */
async function fetchDeviceConfig(
  serverUrl: string,
  identity: Identity,
  logger: Logger
): Promise<{ comPort: string; controllerId: string; baudRate: number } | null> {
  try {
    const url = `${serverUrl}/api/devices/${identity.deviceId}/config`;
    const res = await fetch(url, {
      headers: { 'Authorization': `Bearer ${identity.apiKey}` },
    });
    if (!res.ok) {
      logger.debug(`Fetch device config failed: ${res.status}`);
      return null;
    }
    const json = await res.json() as Record<string, unknown>;
    const data = (json.data || json) as Record<string, unknown>;
    const device = data.device as Record<string, unknown> | undefined;
    const assignedApp = data.assignedApp as Record<string, unknown> | undefined;
    const appConfig = (assignedApp?.config as Record<string, unknown>) || {};

    const comPort = (device?.com_port as string) || '';
    if (!comPort) return null;

    // controllerId comes from app config (MQTT topic identity), defaults to com_port
    const controllerId = (appConfig.controllerId as string) || comPort;
    const baudRate = (device?.baud_rate as number) || 115200;

    return { comPort, controllerId, baudRate };
  } catch (err) {
    logger.debug('Failed to fetch device config:', err);
    return null;
  }
}

main().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
