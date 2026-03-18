import type { CommandHandler } from '../lib/types.js';
import type { Logger } from '../lib/logger.js';
import type { Watchdog } from '../services/watchdog.js';

export function registerMaintenanceCommands(
  register: (command: string, handler: CommandHandler) => void,
  watchdog: Watchdog,
  logger: Logger
): void {
  // maintenance:cleanup — Run disk cleanup immediately
  register('maintenance:cleanup', async () => {
    logger.info('Manual disk cleanup requested');
    const result = await watchdog.runDiskCleanup();
    return { ...result };
  });

  // maintenance:status — Get watchdog recovery stats
  register('maintenance:status', async () => {
    const stats = watchdog.getStats();
    const cooldowns = watchdog.getCooldowns();
    return { stats, cooldowns };
  });
}
