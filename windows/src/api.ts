import { invoke } from "@tauri-apps/api/core";
import type { Account, AccountInput, Bucket, ListPage } from "./types";

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
};
