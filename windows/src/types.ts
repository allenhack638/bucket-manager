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
