export type Account = {
  id: string;
  name: string;
  accessKeyId: string;
  region: string;
  endpoint: string | null;
  bucket: string | null;
  pathStyle: boolean;
};

export type AccountInput = {
  id?: string;
  name: string;
  accessKeyId: string;
  secretAccessKey?: string;
  region: string;
  endpoint?: string;
  bucket?: string;
  pathStyle: boolean;
};

export type Bucket = {
  name: string;
  creationDate: string | null;
};

export type ObjectEntry = {
  key: string;
  name: string;
  kind: "object" | "folder";
  size: number | null;
  lastModified: string | null;
  storageClass: string | null;
  eTag: string | null;
};

export type ListPage = {
  bucket: string;
  prefix: string;
  entries: ObjectEntry[];
  nextToken: string | null;
};

export type TransferTask = {
  id: string;
  kind: "upload" | "download";
  accountId: string;
  bucket: string;
  key: string;
  localPath: string;
  size: number;
  transferred: number;
  status: "queued" | "running" | "paused" | "completed" | "failed" | "cancelled";
  error: string | null;
  multipart: boolean;
  createdAt: number;
};

export type LogLevel = "trace" | "debug" | "info" | "warning" | "error";

export type LogRecord = {
  timestamp: string;
  level: LogLevel;
  category: string;
  event: string;
  message: string;
  outcome?: string | null;
  accountId?: string | null;
  accountName?: string | null;
  operation?: string | null;
  bucket?: string | null;
  key?: string | null;
  metadata?: unknown;
};

export type LogFilter = {
  limit?: number;
  level?: string;
  category?: string;
  accountId?: string;
  query?: string;
};

export type LoggingSettings = {
  diagnosticsEnabled: boolean;
  minimumLevel: string;
  enabledCategories: string[];
  diagnosticRetentionDays: number;
  auditRetentionDays: number;
  includeObjectKeys: boolean;
};

export type RequestMetric = {
  accountId: string;
  accountName: string;
  bucket: string;
  operation: string;
  requests: number;
  failures: number;
  totalMs: number;
  bytes: number;
  lastUsed: string;
  sessionRequests: number;
};
