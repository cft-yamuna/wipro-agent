import { spawn, execSync } from 'child_process';
import type { ChildProcess } from 'child_process';
import type { KioskConfig, KioskStatus } from '../lib/types.js';
import type { Logger } from '../lib/logger.js';

export class KioskManager {
  private config: KioskConfig;
  private logger: Logger;
  private process: ChildProcess | null = null;
  private currentUrl: string | null = null;
  private startedAt: number | null = null;
  private crashTimestamps: number[] = [];
  private crashLoopDetected = false;
  private restarting = false;
  private pollTimer: NodeJS.Timeout | null = null;

  constructor(config: KioskConfig, logger: Logger) {
    this.config = config;
    this.logger = logger;
  }

  async launch(url?: string): Promise<KioskStatus> {
    const targetUrl = url || this.config.defaultUrl;

    // Kill existing process if running
    if (this.process) {
      await this.kill();
    }

    // Kill any leftover Chrome kiosk instances that use our user-data-dir
    this.killExistingKioskChrome();

    // Delay to let Chrome fully release profile lock
    await new Promise((r) => setTimeout(r, 2_000));

    const args = [
      '--kiosk',
      '--noerrdialogs',
      '--disable-infobars',
      '--disable-session-crashed-bubble',
      '--no-first-run',
      '--no-default-browser-check',
      ...this.config.extraArgs,
      targetUrl,
    ];

    this.logger.info(`Launching kiosk: ${this.config.browserPath} → ${targetUrl}`);

    this.process = spawn(this.config.browserPath, args, {
      stdio: 'ignore',
      detached: true,
    });

    // Unref so the agent process isn't held open by Chrome
    this.process.unref();

    this.currentUrl = targetUrl;
    this.startedAt = Date.now();
    this.crashLoopDetected = false;

    this.process.on('exit', (code) => {
      this.handleCrash(code);
    });

    this.process.on('error', (err) => {
      this.logger.error('Kiosk process error:', err.message);
      this.process = null;
      this.handleCrash(1);
    });

    this.startPoll();

    return this.getStatus();
  }

  async kill(): Promise<void> {
    this.stopPoll();

    if (!this.process) {
      return;
    }

    const proc = this.process;
    this.process = null;

    return new Promise<void>((resolve) => {
      let killed = false;

      const onExit = () => {
        if (killed) return;
        killed = true;
        clearTimeout(forceKillTimer);
        resolve();
      };

      const forceKillTimer = setTimeout(() => {
        if (!killed) {
          this.logger.warn('Kiosk did not exit after SIGTERM, sending SIGKILL');
          try {
            proc.kill('SIGKILL');
          } catch {
            // Process may already be dead
          }
        }
      }, 5_000);

      // Remove the crash handler so kill doesn't trigger auto-restart
      proc.removeAllListeners('exit');
      proc.once('exit', onExit);

      try {
        proc.kill('SIGTERM');
      } catch {
        // Process already dead
        onExit();
      }
    });
  }

  async navigate(url: string): Promise<void> {
    this.logger.info(`Navigating kiosk to: ${url}`);
    await this.kill();
    await this.launch(url);
  }

  async restart(): Promise<KioskStatus> {
    this.logger.info('Restarting kiosk');
    this.restarting = true;
    const url = this.currentUrl;
    await this.kill();
    return this.launch(url || undefined);
  }

  getStatus(): KioskStatus {
    const running = this.process !== null && this.process.exitCode === null;
    return {
      running,
      pid: running && this.process ? this.process.pid ?? null : null,
      url: this.currentUrl,
      crashCount: this.crashTimestamps.length,
      crashLoopDetected: this.crashLoopDetected,
      uptimeMs: running && this.startedAt ? Date.now() - this.startedAt : null,
    };
  }

  destroy(): void {
    this.stopPoll();
    if (this.process) {
      try {
        this.process.removeAllListeners();
        this.process.kill('SIGKILL');
      } catch {
        // Process may already be dead
      }
      this.process = null;
    }
  }

  // --- Private Methods ---

  private killExistingKioskChrome(): void {
    try {
      if (process.platform === 'win32') {
        // Kill all Chrome instances — on a kiosk machine the agent owns the browser
        try {
          execSync('taskkill /IM chrome.exe /F', { stdio: 'ignore', timeout: 5_000 });
          this.logger.info('Killed existing Chrome instances');
        } catch {
          // No Chrome running, that's fine
        }
      } else {
        try {
          execSync('pkill -f chromium-browser || pkill -f chrome', { stdio: 'ignore', timeout: 5_000 });
        } catch {
          // No browser running
        }
      }
    } catch {
      // Best effort
    }
  }

  private handleCrash(code: number | null): void {
    // If process was intentionally killed (process set to null), skip
    if (this.process === null) {
      return;
    }

    this.process = null;
    this.stopPoll();

    // If restart() is in progress, skip auto-restart — restart() handles it
    if (this.restarting) {
      this.restarting = false;
      this.logger.info(`Kiosk exited with code ${code} during restart, deferring to restart()`);
      return;
    }

    const now = Date.now();
    const windowStart = now - this.config.crashWindowMs;
    this.crashTimestamps = [...this.crashTimestamps, now].filter((t) => t >= windowStart);

    this.logger.warn(
      `Kiosk exited with code ${code}. Crashes in window: ${this.crashTimestamps.length}/${this.config.maxCrashesInWindow}`
    );

    if (this.crashTimestamps.length >= this.config.maxCrashesInWindow) {
      this.crashLoopDetected = true;
      this.logger.error(
        `Crash loop detected (${this.crashTimestamps.length} crashes in ${this.config.crashWindowMs}ms). NOT restarting.`
      );
      return;
    }

    // Auto-restart after delay
    this.logger.info('Auto-restarting kiosk in 2s...');
    setTimeout(() => {
      this.launch(this.currentUrl || undefined).catch((err) => {
        this.logger.error('Failed to auto-restart kiosk:', err);
      });
    }, 2_000);
  }

  private startPoll(): void {
    this.stopPoll();
    this.pollTimer = setInterval(() => {
      if (this.process && this.process.exitCode !== null) {
        // Process died but exit event didn't fire
        this.logger.warn('Poll detected kiosk process died');
        this.handleCrash(null);
      }
    }, this.config.pollIntervalMs);
  }

  private stopPoll(): void {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
  }
}
