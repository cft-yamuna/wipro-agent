/**
 * Windows Service management via node-windows.
 * This module is only used on Windows machines.
 * node-windows is an optional dependency — install it with:
 *   npm install node-windows
 */

import { resolve } from 'path';

interface NodeWindowsService {
  install(): void;
  uninstall(): void;
  on(event: string, callback: () => void): void;
}

interface NodeWindowsModule {
  Service: new (config: {
    name: string;
    description: string;
    script: string;
    nodeOptions?: string[];
    workingDirectory?: string;
    env?: Array<{ name: string; value: string }>;
    wait?: number;
    grow?: number;
    maxRetries?: number;
  }) => NodeWindowsService;
}

const SERVICE_NAME = 'LIGHTMAN Agent';
const SERVICE_DESCRIPTION = 'LIGHTMAN museum display agent - system monitoring and control';

function getAgentScript(): string {
  return resolve(process.cwd(), 'dist', 'index.js');
}

/**
 * Install the LIGHTMAN Agent as a Windows service.
 * Resolves when install completes, rejects on error.
 */
export async function installService(): Promise<void> {
  const nodeWindows = await loadNodeWindows();

  return new Promise<void>((resolvePromise, reject) => {
    const svc = new nodeWindows.Service({
      name: SERVICE_NAME,
      description: SERVICE_DESCRIPTION,
      script: getAgentScript(),
      nodeOptions: ['--max-old-space-size=256'],
      workingDirectory: process.cwd(),
      env: [
        { name: 'NODE_ENV', value: 'production' },
      ],
      // Crash recovery: restart with growing delay, no max restart limit
      wait: 5,              // 5 seconds before first restart
      grow: 0.5,            // grow delay by 50% each consecutive crash
      maxRetries: -1,       // never stop restarting (-1 = infinite)
    });

    svc.on('install', () => {
      console.log(`Service "${SERVICE_NAME}" installed successfully.`);
      resolvePromise();
    });

    svc.on('error', () => {
      reject(new Error(`Failed to install service "${SERVICE_NAME}"`));
    });

    svc.install();
  });
}

/**
 * Uninstall the LIGHTMAN Agent Windows service.
 * Resolves when uninstall completes, rejects on error.
 */
export async function uninstallService(): Promise<void> {
  const nodeWindows = await loadNodeWindows();

  return new Promise<void>((resolvePromise, reject) => {
    const svc = new nodeWindows.Service({
      name: SERVICE_NAME,
      description: SERVICE_DESCRIPTION,
      script: getAgentScript(),
    });

    svc.on('uninstall', () => {
      console.log(`Service "${SERVICE_NAME}" uninstalled successfully.`);
      resolvePromise();
    });

    svc.on('error', () => {
      reject(new Error(`Failed to uninstall service "${SERVICE_NAME}"`));
    });

    svc.uninstall();
  });
}

/**
 * Dynamically load node-windows (optional dependency).
 */
async function loadNodeWindows(): Promise<NodeWindowsModule> {
  try {
    // Use a variable so TypeScript does not statically resolve the optional module
    const moduleName = 'node-windows';
    const mod = await import(moduleName) as unknown as NodeWindowsModule;
    return mod;
  } catch {
    throw new Error(
      'node-windows is not installed. Run: npm install node-windows'
    );
  }
}
