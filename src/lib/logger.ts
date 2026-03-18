import { appendFileSync, existsSync, mkdirSync } from 'fs';
import { dirname } from 'path';
import type { LogEntry } from './types.js';

type LogLevel = 'debug' | 'info' | 'warn' | 'error';

const LEVEL_ORDER: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
};

const LEVEL_LABELS: Record<LogLevel, string> = {
  debug: 'DEBUG',
  info: 'INFO ',
  warn: 'WARN ',
  error: 'ERROR',
};

export class Logger {
  private level: LogLevel;
  private logFile: string | null;
  private listeners: Array<(entry: LogEntry) => void> = [];

  constructor(level: LogLevel = 'info', logFile?: string) {
    this.level = level;
    this.logFile = logFile || null;

    if (this.logFile) {
      const dir = dirname(this.logFile);
      if (!existsSync(dir)) {
        mkdirSync(dir, { recursive: true });
      }
    }
  }

  onLog(fn: (entry: LogEntry) => void): void {
    this.listeners = [...this.listeners, fn];
  }

  setLevel(level: LogLevel): void {
    this.level = level;
  }

  debug(message: string, ...args: unknown[]): void {
    this.log('debug', message, ...args);
  }

  info(message: string, ...args: unknown[]): void {
    this.log('info', message, ...args);
  }

  warn(message: string, ...args: unknown[]): void {
    this.log('warn', message, ...args);
  }

  error(message: string, ...args: unknown[]): void {
    this.log('error', message, ...args);
  }

  private log(level: LogLevel, message: string, ...args: unknown[]): void {
    if (LEVEL_ORDER[level] < LEVEL_ORDER[this.level]) {
      return;
    }

    const timestamp = new Date().toISOString();
    const label = LEVEL_LABELS[level];
    const formatted = `[${timestamp}] [${label}] ${message}`;

    // Console output
    if (level === 'error') {
      console.error(formatted, ...args);
    } else if (level === 'warn') {
      console.warn(formatted, ...args);
    } else {
      console.log(formatted, ...args);
    }

    // File output
    if (this.logFile) {
      try {
        const extra = args.length > 0 ? ' ' + args.map(a => JSON.stringify(a)).join(' ') : '';
        appendFileSync(this.logFile, formatted + extra + '\n');
      } catch {
        // Silently fail file writes to avoid recursive errors
      }
    }

    // Notify listeners
    const entry: LogEntry = { timestamp, level, message, source: 'agent' };
    for (const listener of this.listeners) {
      try {
        listener(entry);
      } catch {
        // Prevent listener errors from breaking logging
      }
    }
  }
}
