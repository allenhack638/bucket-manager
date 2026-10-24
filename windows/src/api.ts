import { invoke } from "@tauri-apps/api/core";
import type {
  Account,
  AccountInput,
  Bucket,
  CopyItem,
  ListPage,
  LogFilter,
  LogRecord,
  LoggingSettings,
  RequestMetric,
  TransferTask,
} from "./types";

export const api = {
  listAccounts: () => invoke<Account[]>("list_accounts"),
  saveAccount: (input: AccountInput) => invoke<Account>("save_account", { input }),
  deleteAccount: (id: string) => invoke<void>("delete_account", { id }),
  testConnection: (id: string) => invoke<string>("test_connection", { id }),
  listBuckets: (id: string) => invoke<Bucket[]>("list_buckets", { id }),
  createBucket: (id: string, bucket: string) => invoke<void>("create_bucket", { id, bucket }),
  deleteBucket: (id: string, bucket: string) => invoke<void>("delete_bucket", { id, bucket }),
  listObjects: (id: string, bucket: string, prefix: string, continuationToken?: string) =>
    invoke<ListPage>("list_objects", {
      id,
      bucket,
      prefix,
      continuationToken: continuationToken ?? null,
    }),
  uploadObject: (id: string, bucket: string, key: string, filePath: string) =>
    invoke<void>("upload_object", { id, bucket, key, filePath }),
  downloadObject: (id: string, bucket: string, key: string, destination: string) =>
    invoke<void>("download_object", { id, bucket, key, destination }),
  deleteObject: (id: string, bucket: string, key: string) =>
    invoke<void>("delete_object", { id, bucket, key }),
  createFolder: (id: string, bucket: string, key: string) =>
    invoke<void>("create_folder", { id, bucket, key }),
  listTransfers: () => invoke<TransferTask[]>("list_transfers"),
  getLogs: (filter: LogFilter) => invoke<LogRecord[]>("get_logs", { filter }),
  getLoggingSettings: () => invoke<LoggingSettings>("get_logging_settings"),
  saveLoggingSettings: (settings: LoggingSettings) =>
    invoke<void>("save_logging_settings", { settings }),
  clearDiagnostics: () => invoke<number>("clear_diagnostics"),
  exportLogs: (destination: string, filter: LogFilter) =>
    invoke<number>("export_logs", { destination, filter }),
  revealLogs: () => invoke<void>("reveal_logs"),
  getStatistics: () => invoke<RequestMetric[]>("get_statistics"),
  clearStatistics: () => invoke<void>("clear_statistics"),
  openLogsWindow: (tab: "logs" | "statistics" | "settings" = "logs") =>
    invoke<void>("open_logs_window", { tab }),
  takeLogsTab: () => invoke<string | null>("take_logs_tab"),
  enqueueUpload: (id: string, bucket: string, key: string, filePath: string) =>
    invoke<TransferTask>("enqueue_upload", { id, bucket, key, filePath }),
  enqueueDownload: (id: string, bucket: string, key: string, destination: string, size: number) =>
    invoke<TransferTask>("enqueue_download", { id, bucket, key, destination, size }),
  startCrossAccountTransfer: (input: {
    sourceAccountId: string;
    sourceBucket: string;
    sourcePrefix: string;
    destinationAccountId: string;
    destinationBucket: string;
    destinationPrefix: string;
    items: CopyItem[];
    moveSource: boolean;
  }) => invoke<TransferTask[]>("start_cross_account_transfer", input),
  pauseTransfer: (id: string) => invoke<void>("pause_transfer", { id }),
  resumeTransfer: (id: string) => invoke<void>("resume_transfer", { id }),
  cancelTransfer: (id: string) => invoke<void>("cancel_transfer", { id }),
  retryTransfer: (id: string) => invoke<void>("retry_transfer", { id }),
};
