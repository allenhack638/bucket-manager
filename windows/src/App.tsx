import {
  useCallback,
  useEffect,
  useMemo,
  useState,
  type FormEvent,
  type MouseEvent as ReactMouseEvent,
  type ReactNode,
} from "react";
import { listen } from "@tauri-apps/api/event";
import { open, save } from "@tauri-apps/plugin-dialog";
import { api } from "./api";
import { applyAppearance, initAppearance, type Appearance } from "./theme";
import type { Account, AccountInput, Bucket, ListPage, ObjectEntry } from "./types";

type SortKey = "name" | "size" | "modified" | "storage";

const TABS = [
  ["tasks", "Tasks"],
  ["permissions", "Permissions"],
  ["headers", "Headers"],
  ["tags", "Tags"],
  ["properties", "Properties"],
  ["preview", "Preview"],
  ["versions", "Versions"],
  ["events", "Event Log"],
] as const;

function joinKey(prefix: string, name: string) {
  return `${prefix}${name}`;
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function formatSize(bytes: number | null) {
  if (bytes === null) return "—";
  if (bytes === 0) return "0 bytes";
  if (bytes < 1024) return `${bytes} bytes`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(value >= 10 ? 0 : 1)} ${units[unit]}`;
}

function formatDate(value: string | null) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("en-US", {
    month: "numeric",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
    second: "2-digit",
    hour12: true,
  }).format(date);
}

function objectType(entry: ObjectEntry) {
  if (entry.kind === "folder") return "Folder";
  const extension = entry.name.split(".").pop()?.toLowerCase() ?? "";
  const types: Record<string, string> = {
    png: "PNG File",
    jpg: "JPEG File",
    jpeg: "JPEG File",
    gif: "GIF File",
    webp: "WebP File",
    svg: "SVG File",
    pdf: "PDF Document",
    txt: "Text File",
    json: "JSON File",
    csv: "CSV File",
    zip: "ZIP Archive",
    mp4: "MP4 Video",
    mov: "QuickTime Movie",
    mp3: "MP3 Audio",
  };
  return types[extension] ?? (extension ? `${extension.toUpperCase()} File` : "File");
}

function Icon({ name }: { name: string }) {
  const paths: Record<string, ReactNode> = {
    bucket: (
      <>
        <path d="M4 7h16l-1.5 12h-13z" />
        <path d="M7 4h10M8 11h8" />
      </>
    ),
    folder: <path d="M3.5 6.5h6l2 2h9v9.5a2 2 0 0 1-2 2h-15a2 2 0 0 1-2-2V8.5a2 2 0 0 1 2-2Z" />,
    file: (
      <>
        <path d="M6 3.5h7l5 5v12H6z" />
        <path d="M13 3.5v5h5" />
      </>
    ),
    plus: <path d="M12 5v14M5 12h14" />,
    refresh: (
      <>
        <path d="M20 11a8 8 0 1 0-2.3 5.7" />
        <path d="M20 5v6h-6" />
      </>
    ),
    upload: (
      <>
        <path d="M12 16V4m0 0L7 9m5-5 5 5" />
        <path d="M4 15v5h16v-5" />
      </>
    ),
    download: (
      <>
        <path d="M12 4v12m0 0 5-5m-5 5-5-5" />
        <path d="M4 19h16" />
      </>
    ),
    open: <path d="M5 19 19 5M8 5h11v11" />,
    trash: <path d="M4 7h16M9 7V4h6v3M7 7l1 13h8l1-13M10 11v5M14 11v5" />,
    folderPlus: (
      <>
        <path d="M3.5 6.5h6l2 2h9v9.5a2 2 0 0 1-2 2h-15a2 2 0 0 1-2-2V8.5a2 2 0 0 1 2-2Z" />
        <path d="M15 13v5m-2.5-2.5h5" />
      </>
    ),
    star: <path d="m12 3 2.8 5.7 6.2.9-4.5 4.4 1.1 6.2L12 17.3l-5.6 2.9 1.1-6.2L3 9.6l6.2-.9z" />,
    pencil: <path d="m4 20 4.2-1 10.6-10.6a2 2 0 0 0-2.8-2.8L5.4 16.2z" />,
    filter: <path d="M4 6h16M7 12h10M10 18h4" />,
    chevronUp: <path d="m6 15 6-6 6 6" />,
    chevronDown: <path d="m6 9 6 6 6-6" />,
    play: <path d="m8 5 10 7-10 7z" />,
    stop: <rect x="6" y="6" width="12" height="12" rx="1" />,
    cancel: <path d="M6 6l12 12M18 6 6 18" />,
  };
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      {paths[name] ?? paths.file}
    </svg>
  );
}

function AccountDialog({
  account,
  onClose,
  onSaved,
}: {
  account?: Account;
  onClose: () => void;
  onSaved: (account: Account) => void;
}) {
  const [form, setForm] = useState<AccountInput>({
    id: account?.id,
    name: account?.name ?? "",
    accessKeyId: account?.accessKeyId ?? "",
    secretAccessKey: "",
    region: account?.region ?? "us-east-1",
    endpoint: account?.endpoint ?? "",
    bucket: account?.bucket ?? "",
    pathStyle: account?.pathStyle ?? false,
  });
  const [saving, setSaving] = useState(false);
  const [testing, setTesting] = useState(false);
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");

  const update = <K extends keyof AccountInput>(key: K, value: AccountInput[K]) =>
    setForm((current) => ({ ...current, [key]: value }));

  const payload = (): AccountInput => ({
    ...form,
    name: form.name.trim(),
    accessKeyId: form.accessKeyId.trim(),
    region: form.region.trim(),
    endpoint: form.endpoint?.trim() || undefined,
    bucket: form.bucket?.trim() || undefined,
    secretAccessKey: form.secretAccessKey?.trim() || undefined,
  });

  const save = async (testAfter: boolean) => {
    setError("");
    setStatus("");
    if (!form.name.trim() || !form.accessKeyId.trim() || !form.region.trim()) {
      setError("Display name, access key ID, and region are required.");
      return;
    }
    if (!account && !form.secretAccessKey?.trim()) {
      setError("Secret access key is required for a new account.");
      return;
    }
    setSaving(true);
    try {
      const saved = await api.saveAccount(payload());
      if (testAfter) {
        setTesting(true);
        setStatus(await api.testConnection(saved.id));
      }
      onSaved(saved);
    } catch (nextError) {
      setError(errorMessage(nextError));
    } finally {
      setTesting(false);
      setSaving(false);
    }
  };

  const submit = (event: FormEvent) => {
    event.preventDefault();
    void save(false);
  };

  return (
    <div className="sheet-backdrop" role="presentation" onMouseDown={onClose}>
      <form className="account-sheet" onSubmit={submit} onMouseDown={(event) => event.stopPropagation()}>
        <div className="sheet-title">
          <div className="sheet-cloud">
            <Icon name="bucket" />
          </div>
          <div>
            <h2>{account ? "Edit Account" : "Add Account"}</h2>
            <p>Enter the account details and click Save changes.</p>
          </div>
        </div>

        <div className="sheet-fields">
          <div className="sheet-field">
            <label htmlFor="display-name">Display name:</label>
            <div>
              <input
                id="display-name"
                autoFocus
                value={form.name}
                onChange={(event) => update("name", event.target.value)}
                placeholder="S3-Compatible Storage"
              />
              <small>Assign any name to your account.</small>
            </div>
          </div>

          <div className="sheet-field">
            <label htmlFor="access-key">Access Key ID:</label>
            <div>
              <input
                id="access-key"
                value={form.accessKeyId}
                onChange={(event) => update("accessKeyId", event.target.value)}
                placeholder="EXAMPLE000000000000"
                autoComplete="off"
              />
              <small>Required to sign the requests you send to Amazon S3.</small>
            </div>
          </div>

          <div className="sheet-field">
            <label htmlFor="secret-key">Secret Access Key:</label>
            <div>
              <input
                id="secret-key"
                type="password"
                value={form.secretAccessKey}
                onChange={(event) => update("secretAccessKey", event.target.value)}
                placeholder={account ? "Leave blank to keep existing" : ""}
                autoComplete="new-password"
              />
              <small>
                {account
                  ? "Leave blank to keep the current secret in Windows Credential Manager."
                  : "Stored in Windows Credential Manager; no secret is written to accounts.json."}
              </small>
            </div>
          </div>

          <div className="sheet-field">
            <label htmlFor="region">Region:</label>
            <div>
              <input
                id="region"
                value={form.region}
                onChange={(event) => update("region", event.target.value)}
                placeholder="us-east-1"
              />
              <small>For example us-east-1. Must match the bucket’s region.</small>
            </div>
          </div>

          <div className="sheet-field">
            <label htmlFor="endpoint">Custom endpoint:</label>
            <div>
              <input
                id="endpoint"
                value={form.endpoint}
                onChange={(event) => update("endpoint", event.target.value)}
                placeholder="https://s3.example.com"
              />
              <small>
                For MinIO, Wasabi, Cloudflare R2, Backblaze B2 and other S3-compatible services.
                HTTPS is required for remote hosts.
              </small>
            </div>
          </div>

          <div className="sheet-field">
            <label htmlFor="bucket-name">Bucket (optional):</label>
            <div>
              <input
                id="bucket-name"
                value={form.bucket}
                onChange={(event) => update("bucket", event.target.value)}
                placeholder="bucket-name (optional)"
              />
              <small>Required for bucket-scoped keys that cannot list all buckets.</small>
            </div>
          </div>

          <div className="sheet-field sheet-checkbox-field">
            <label>Addressing:</label>
            <div>
              <label className="check-line">
                <input
                  type="checkbox"
                  checked={form.pathStyle}
                  onChange={(event) => update("pathStyle", event.target.checked)}
                />
                Use path-style addressing
              </label>
              <label className="check-line">
                <input type="checkbox" checked readOnly />
                Use secure transfer (SSL/TLS)
              </label>
              <small>Secrets are stored in Windows Credential Manager; no secret is written to accounts.json.</small>
            </div>
          </div>
        </div>

        {error && <div className="sheet-error">{error}</div>}
        {status && <div className="sheet-status">{status}</div>}

        <div className="sheet-actions">
          <button
            className="link-button"
            type="button"
            disabled={saving || testing || !account}
            onClick={() => void save(true)}
          >
            {testing ? "Testing…" : "Test connection"}
          </button>
          <span className="sheet-actions-right">
            <button className="button secondary" type="button" onClick={onClose}>
              Cancel
            </button>
            <button className="button primary" type="submit" disabled={saving}>
              {saving ? "Saving…" : account ? "Save changes" : "Add account"}
            </button>
          </span>
        </div>
      </form>
    </div>
  );
}

export default function App() {
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [accountId, setAccountId] = useState("");
  const [buckets, setBuckets] = useState<Bucket[]>([]);
  const [bucket, setBucket] = useState("");
  const [prefix, setPrefix] = useState("");
  const [page, setPage] = useState<ListPage | null>(null);
  const [selectedKeys, setSelectedKeys] = useState<Set<string>>(new Set());
  const [filter, setFilter] = useState("");
  const [showFilter, setShowFilter] = useState(false);
  const [sortKey, setSortKey] = useState<SortKey>("name");
  const [sortAscending, setSortAscending] = useState(true);
  const [tab, setTab] = useState<string>("tasks");
  const [loadingAccounts, setLoadingAccounts] = useState(true);
  const [loadingBuckets, setLoadingBuckets] = useState(false);
  const [loadingObjects, setLoadingObjects] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [refreshTick, setRefreshTick] = useState(0);
  const [dialog, setDialog] = useState<{ account?: Account } | null>(null);

  const activeAccount = useMemo(
    () => accounts.find((account) => account.id === accountId),
    [accounts, accountId],
  );

  const loadAccounts = useCallback(async () => {
    try {
      const next = await api.listAccounts();
      setAccounts(next);
      setAccountId((current) =>
        next.some((account) => account.id === current) ? current : (next[0]?.id ?? ""),
      );
    } catch (nextError) {
      setError(errorMessage(nextError));
    } finally {
      setLoadingAccounts(false);
    }
  }, []);

  useEffect(() => {
    void loadAccounts();
  }, [loadAccounts]);

  useEffect(() => {
    void initAppearance();
    let active = true;
    let unlisten: (() => void) | undefined;
    void listen<Appearance>("appearance-changed", (event) => {
      applyAppearance(event.payload);
    }).then((stop) => {
      if (active) unlisten = stop;
      else stop();
    });
    return () => {
      active = false;
      unlisten?.();
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    setBuckets([]);
    setBucket("");
    setPrefix("");
    setPage(null);
    setSelectedKeys(new Set());
    if (!accountId) return;

    setLoadingBuckets(true);
    api
      .listBuckets(accountId)
      .then((nextBuckets) => {
        if (cancelled) return;
        setBuckets(nextBuckets);
        const preferred = activeAccount?.bucket;
        const preferredExists = preferred && nextBuckets.some((item) => item.name === preferred);
        setBucket(preferredExists ? preferred : (nextBuckets[0]?.name ?? ""));
      })
      .catch((nextError) => {
        if (!cancelled) setError(errorMessage(nextError));
      })
      .finally(() => {
        if (!cancelled) setLoadingBuckets(false);
      });

    return () => {
      cancelled = true;
    };
  }, [accountId, activeAccount?.bucket]);

  useEffect(() => {
    let cancelled = false;
    if (!accountId || !bucket) {
      setPage(null);
      return;
    }

    setLoadingObjects(true);
    setError("");
    api
      .listObjects(accountId, bucket, prefix)
      .then((nextPage) => {
        if (cancelled) return;
        setPage(nextPage);
        setSelectedKeys(new Set());
      })
      .catch((nextError) => {
        if (!cancelled) setError(errorMessage(nextError));
      })
      .finally(() => {
        if (!cancelled) setLoadingObjects(false);
      });

    return () => {
      cancelled = true;
    };
  }, [accountId, bucket, prefix, refreshTick]);

  const entries = useMemo(() => {
    const source = page?.entries ?? [];
    const filtered = filter.trim()
      ? source.filter((entry) => entry.name.toLowerCase().includes(filter.trim().toLowerCase()))
      : source;
    return [...filtered].sort((left, right) => {
      if (left.kind !== right.kind) return left.kind === "folder" ? -1 : 1;
      let result = 0;
      if (sortKey === "name") result = left.name.localeCompare(right.name);
      if (sortKey === "size") result = (left.size ?? 0) - (right.size ?? 0);
      if (sortKey === "modified") result = (left.lastModified ?? "").localeCompare(right.lastModified ?? "");
      if (sortKey === "storage") result = (left.storageClass ?? "").localeCompare(right.storageClass ?? "");
      return sortAscending ? result : -result;
    });
  }, [page?.entries, filter, sortKey, sortAscending]);

  const selectedEntries = useMemo(
    () => entries.filter((entry) => selectedKeys.has(entry.key)),
    [entries, selectedKeys],
  );
  const selectedEntry = selectedEntries[selectedEntries.length - 1] ?? null;
  const visibleTotalSize = entries.reduce((sum, entry) => sum + (entry.size ?? 0), 0);

  const breadcrumb = useMemo(() => {
    const parts = prefix.split("/").filter(Boolean);
    const result: { name: string; prefix: string }[] = [];
    let current = "";
    for (const part of parts) {
      current += `${part}/`;
      result.push({ name: part, prefix: current });
    }
    return result;
  }, [prefix]);

  const toggleSelected = (key: string) => {
    setSelectedKeys((current) => {
      const next = new Set(current);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };

  const selectRow = (entry: ObjectEntry, event: ReactMouseEvent) => {
    if (event.metaKey || event.ctrlKey || event.shiftKey) {
      toggleSelected(entry.key);
    } else {
      setSelectedKeys(new Set([entry.key]));
    }
  };

  const refresh = () => {
    setRefreshTick((value) => value + 1);
    setSelectedKeys(new Set());
  };

  const refreshBuckets = async () => {
    if (!accountId) return;
    setLoadingBuckets(true);
    try {
      const nextBuckets = await api.listBuckets(accountId);
      setBuckets(nextBuckets);
      if (!nextBuckets.some((item) => item.name === bucket)) {
        setBucket(nextBuckets[0]?.name ?? "");
      }
      setRefreshTick((value) => value + 1);
    } catch (nextError) {
      setError(errorMessage(nextError));
    } finally {
      setLoadingBuckets(false);
    }
  };

  const createBucket = async () => {
    if (!accountId || busy) return;
    const name = window.prompt("New bucket", "bucket-name");
    const cleaned = name?.trim();
    if (!cleaned) return;
    setBusy(true);
    setError("");
    try {
      await api.createBucket(accountId, cleaned);
      await refreshBuckets();
      setBucket(cleaned);
    } catch (nextError) {
      setError(errorMessage(nextError));
    } finally {
      setBusy(false);
    }
  };

  const uploadFiles = async () => {
    if (!accountId || !bucket || busy) return;
    let picked: string | string[] | null;
    try {
      picked = await open({ multiple: true, title: "Upload files" });
    } catch (nextError) {
      setError(`File dialog failed: ${errorMessage(nextError)}`);
      return;
    }
    const paths = Array.isArray(picked) ? picked : picked ? [picked] : [];
    if (!paths.length) return;

    setBusy(true);
    setError("");
    try {
      for (const path of paths) {
        const name = path.split(/[\\/]/).pop();
        if (!name) continue;
        await api.uploadObject(accountId, bucket, joinKey(prefix, name), path);
      }
      refresh();
    } catch (nextError) {
      setError(errorMessage(nextError));
    } finally {
      setBusy(false);
    }
  };

  const downloadEntries = async (targets: ObjectEntry[]) => {
    if (!accountId || !bucket || busy) return;
    const files = targets.filter((entry) => entry.kind === "object");
    if (!files.length) return;
    setBusy(true);
    setError("");
    try {
      for (const entry of files) {
        let destination: string | null;
        try {
          destination = await save({ title: "Download object", defaultPath: entry.name });
        } catch (nextError) {
          setError(`Save dialog failed: ${errorMessage(nextError)}`);
          break;
        }
        if (!destination) break;
        await api.downloadObject(accountId, bucket, entry.key, destination);
      }
    } catch (nextError) {
      setError(errorMessage(nextError));
    } finally {
      setBusy(false);
    }
  };

  const deleteEntries = async (targets: ObjectEntry[]) => {
    if (!accountId || !bucket || busy || !targets.length) return;
    if (!window.confirm(`Delete ${targets.length} item${targets.length === 1 ? "" : "s"}? This cannot be undone.`)) {
      return;
    }

    setBusy(true);
    setError("");
    try {
      for (const entry of targets) {
        await api.deleteObject(accountId, bucket, entry.key);
      }
      refresh();
    } catch (nextError) {
      setError(errorMessage(nextError));
    } finally {
      setBusy(false);
    }
  };

  const createFolder = async () => {
    if (!accountId || !bucket || busy) return;
    const name = window.prompt("New Folder", "New folder");
    const cleaned = name?.trim().replace(/^\/+|\/+$/g, "");
    if (!cleaned) return;

    setBusy(true);
    setError("");
    try {
      await api.createFolder(accountId, bucket, `${joinKey(prefix, cleaned)}/`);
      refresh();
    } catch (nextError) {
      setError(errorMessage(nextError));
    } finally {
      setBusy(false);
    }
  };

  const openEntry = (entry: ObjectEntry) => {
    if (entry.kind === "folder") {
      setPrefix(entry.key.endsWith("/") ? entry.key : `${entry.key}/`);
      setSelectedKeys(new Set());
    } else {
      void downloadEntries([entry]);
    }
  };

  const loadMore = async () => {
    if (!accountId || !bucket || !page?.nextToken || loadingObjects) return;
    setLoadingObjects(true);
    try {
      const nextPage = await api.listObjects(accountId, bucket, prefix, page.nextToken);
      setPage((current) =>
        current
          ? { ...current, entries: [...current.entries, ...nextPage.entries], nextToken: nextPage.nextToken }
          : nextPage,
      );
    } catch (nextError) {
      setError(errorMessage(nextError));
    } finally {
      setLoadingObjects(false);
    }
  };

  const sortBy = (key: SortKey) => {
    if (sortKey === key) setSortAscending((value) => !value);
    else {
      setSortKey(key);
      setSortAscending(true);
    }
  };

  if (loadingAccounts) {
    return <div className="boot">Loading accounts…</div>;
  }

  const accountOptions = [
    ...accounts.map((account) => ({ value: account.id, label: account.name })),
    { value: "__add__", label: "Add account…" },
    ...(activeAccount ? [{ value: "__edit__", label: "Edit account…" }] : []),
  ];

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="account-toolbar">
          <select
            className="account-select"
            value={accountId}
            aria-label="Active account"
            onChange={(event) => {
              const value = event.target.value;
              if (value === "__add__") {
                setDialog({});
                return;
              }
              if (value === "__edit__") {
                if (activeAccount) setDialog({ account: activeAccount });
                return;
              }
              setAccountId(value);
            }}
          >
            {accountOptions.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </select>
          <button
            className="sidebar-action with-label"
            type="button"
            onClick={() => void createBucket()}
            disabled={!accountId || busy}
            title="Create a bucket in the active account"
          >
            <Icon name="plus" />
            <span>New bucket</span>
          </button>
          <button
            className="sidebar-action"
            type="button"
            onClick={() => void refreshBuckets()}
            disabled={!accountId || loadingBuckets}
            title="Refresh buckets list (F5)"
            aria-label="Refresh buckets list"
          >
            <Icon name="refresh" />
          </button>
        </div>

        <div className="bucket-list">
          {loadingBuckets ? (
            <div className="sidebar-empty">Loading buckets…</div>
          ) : buckets.length === 0 ? (
            <div className="sidebar-empty-state">
              <Icon name="bucket" />
              <strong>{accountId ? "No buckets" : "No storage accounts yet"}</strong>
              <p>
                {accountId
                  ? "Create a bucket in this account to get started."
                  : "Add an S3 account to start browsing buckets."}
              </p>
              <button
                className="button primary"
                type="button"
                onClick={() => (accountId ? void createBucket() : setDialog({}))}
              >
                {accountId ? "New bucket" : "Add new account"}
              </button>
            </div>
          ) : (
            buckets.map((item) => (
              <button
                type="button"
                key={item.name}
                className={`bucket-row ${item.name === bucket ? "selected" : ""}`}
                onClick={() => {
                  setBucket(item.name);
                  setPrefix("");
                  setSelectedKeys(new Set());
                }}
              >
                <Icon name="folder" />
                <span>{item.name}</span>
              </button>
            ))
          )}
        </div>
      </aside>

      <main className="main">
        <div className="path-bar">
          <div className="breadcrumbs">
            <button type="button" onClick={() => setPrefix("")} disabled={!bucket}>
              /
            </button>
            {bucket && (
              <button type="button" onClick={() => setPrefix("")}>
                {bucket}/
              </button>
            )}
            {breadcrumb.map((item) => (
              <button type="button" key={item.prefix} onClick={() => setPrefix(item.prefix)}>
                {item.name}/
              </button>
            ))}
          </div>
          <div className="path-tools">
            {showFilter && (
              <input
                className="filter-field"
                autoFocus
                value={filter}
                onChange={(event) => setFilter(event.target.value)}
                placeholder="Filter objects"
              />
            )}
            <button className="icon-button" type="button" title="Bookmark this location" aria-label="Bookmark this location">
              <Icon name="star" />
            </button>
            <button className="icon-button" type="button" title="Rename selected object" aria-label="Rename selected object">
              <Icon name="pencil" />
            </button>
            <button
              className={`icon-button ${showFilter ? "active" : ""}`}
              type="button"
              title="Filter objects"
              aria-label="Filter objects"
              onClick={() => setShowFilter((value) => !value)}
            >
              <Icon name="filter" />
            </button>
            <button className="icon-button" type="button" title="Refresh" aria-label="Refresh" onClick={refresh}>
              <Icon name="refresh" />
            </button>
          </div>
        </div>

        {error && (
          <div className="error-banner">
            <span>{error}</span>
            <button type="button" onClick={() => setError("")}>
              Dismiss
            </button>
          </div>
        )}

        {!accountId ? (
          <div className="browser-empty">
            <Icon name="bucket" />
            <h2>No storage accounts yet</h2>
            <p>Add an S3 account to start browsing buckets.</p>
            <button className="button primary" type="button" onClick={() => setDialog({})}>
              Add new account
            </button>
          </div>
        ) : !bucket ? (
          <div className="browser-empty">
            <Icon name="bucket" />
            <h2>No buckets</h2>
            <p>Create a bucket in this account to get started.</p>
            <button className="button primary" type="button" onClick={() => void createBucket()}>
              New bucket
            </button>
          </div>
        ) : (
          <>
            <div className="file-header">
              <div className="cell check-cell">
                <input
                  type="checkbox"
                  aria-label="Select all"
                  checked={entries.length > 0 && selectedKeys.size === entries.length}
                  onChange={(event) =>
                    setSelectedKeys(event.target.checked ? new Set(entries.map((entry) => entry.key)) : new Set())
                  }
                />
              </div>
              <button className="header-cell name-cell" type="button" onClick={() => sortBy("name")}>
                Name {sortKey === "name" && <Icon name={sortAscending ? "chevronUp" : "chevronDown"} />}
              </button>
              <button className="header-cell size-cell" type="button" onClick={() => sortBy("size")}>
                Size {sortKey === "size" && <Icon name={sortAscending ? "chevronUp" : "chevronDown"} />}
              </button>
              <div className="header-cell type-cell">Type</div>
              <button className="header-cell modified-cell" type="button" onClick={() => sortBy("modified")}>
                Last Modified {sortKey === "modified" && <Icon name={sortAscending ? "chevronUp" : "chevronDown"} />}
              </button>
              <button className="header-cell storage-cell" type="button" onClick={() => sortBy("storage")}>
                Storage Class {sortKey === "storage" && <Icon name={sortAscending ? "chevronUp" : "chevronDown"} />}
              </button>
            </div>

            <div className="file-scroll">
              {loadingObjects && !page ? (
                <div className="table-message">Loading objects…</div>
              ) : entries.length === 0 ? (
                <div className="table-message">{filter ? "No matching objects." : "This folder is empty."}</div>
              ) : (
                entries.map((entry) => {
                  const selected = selectedKeys.has(entry.key);
                  return (
                    <div
                      className={`file-row ${selected ? "selected" : ""}`}
                      key={`${entry.kind}:${entry.key}`}
                      role="row"
                      tabIndex={0}
                      onClick={(event) => selectRow(entry, event)}
                      onDoubleClick={() => openEntry(entry)}
                      onKeyDown={(event) => {
                        if (event.key === "Enter") openEntry(entry);
                        if (event.key === " ") {
                          event.preventDefault();
                          toggleSelected(entry.key);
                        }
                      }}
                    >
                      <div className="cell check-cell">
                        <input
                          type="checkbox"
                          aria-label={`Select ${entry.name}`}
                          checked={selected}
                          onClick={(event) => event.stopPropagation()}
                          onChange={() => toggleSelected(entry.key)}
                        />
                      </div>
                      <div className="cell name-cell">
                        <span className={`row-icon ${entry.kind}`}>
                          <Icon name={entry.kind === "folder" ? "folder" : "file"} />
                        </span>
                        <span className="row-name">{entry.name}</span>
                      </div>
                      <div className="cell size-cell">{formatSize(entry.size)}</div>
                      <div className="cell type-cell">{objectType(entry)}</div>
                      <div className="cell modified-cell">{formatDate(entry.lastModified)}</div>
                      <div className="cell storage-cell">
                        {entry.storageClass || (entry.kind === "folder" ? "—" : "STANDARD")}
                      </div>
                    </div>
                  );
                })
              )}
            </div>

            <div className="browser-status">
              <span className={error ? "warning" : ""}>{error ? "Error" : loadingObjects ? "Loading…" : "Ready"}</span>
              {page?.nextToken && (
                <button className="link-button" type="button" onClick={() => void loadMore()} disabled={loadingObjects}>
                  Load more…
                </button>
              )}
              <span className="count-label">
                {entries.length} files ({formatSize(visibleTotalSize)})
                {selectedEntries.length > 0 &&
                  `, ${selectedEntries.length} file${selectedEntries.length === 1 ? "" : "s"} selected`}
              </span>
            </div>

            <div className="action-bar">
              <button className="action-button upload" type="button" onClick={() => void uploadFiles()} disabled={busy}>
                <Icon name="upload" />
                Upload
              </button>
              <button
                className="action-button download"
                type="button"
                onClick={() => void downloadEntries(selectedEntries)}
                disabled={!selectedEntries.some((entry) => entry.kind === "object") || busy}
              >
                <Icon name="download" />
                Download
              </button>
              <button
                className="action-button open"
                type="button"
                onClick={() => selectedEntry && openEntry(selectedEntry)}
                disabled={!selectedEntry || busy}
              >
                <Icon name="open" />
                Open
              </button>
              <button
                className="action-button delete"
                type="button"
                onClick={() => void deleteEntries(selectedEntries)}
                disabled={!selectedEntries.length || busy}
              >
                <Icon name="trash" />
                Delete
              </button>
              <button className="action-button folder" type="button" onClick={() => void createFolder()} disabled={busy}>
                <Icon name="folderPlus" />
                New Folder
              </button>
              <button className="action-button refresh" type="button" onClick={refresh} disabled={busy}>
                <Icon name="refresh" />
                Refresh
              </button>
            </div>

            <div className="tab-bar">
              {TABS.map(([id, label]) => (
                <button
                  key={id}
                  type="button"
                  className={`tab ${tab === id ? "selected" : ""}`}
                  onClick={() => setTab(id)}
                >
                  {label}
                  {id === "tasks" && " (0)"}
                </button>
              ))}
            </div>

            <div className="inspector">
              {tab === "tasks" && <div className="inspector-empty">No transfers in this session.</div>}
              {tab === "permissions" && (
                <div className="inspector-empty">Select an object to view its permissions.</div>
              )}
              {tab === "headers" && (
                <div className="inspector-details">
                  {selectedEntry
                    ? [
                        ["Key", selectedEntry.key],
                        ["Size", formatSize(selectedEntry.size)],
                        ["Type", objectType(selectedEntry)],
                        ["Last Modified", formatDate(selectedEntry.lastModified)],
                        ["ETag", selectedEntry.eTag ?? "—"],
                        ["Storage Class", selectedEntry.storageClass ?? "—"],
                      ].map(([key, value]) => (
                        <div className="detail-row" key={key}>
                          <span>{key}</span>
                          <code>{value}</code>
                        </div>
                      ))
                    : "Select an object to inspect its headers."}
                </div>
              )}
              {(tab === "tags" || tab === "versions") && (
                <div className="inspector-empty">
                  {tab === "tags" ? "No tags loaded for this object." : "No versions loaded for this object."}
                </div>
              )}
              {tab === "properties" && (
                <div className="inspector-details">
                  {selectedEntry
                    ? [
                        ["Name", selectedEntry.name],
                        ["Kind", selectedEntry.kind === "folder" ? "Folder" : "Object"],
                        ["Storage Class", selectedEntry.storageClass ?? "—"],
                        ["Bucket", bucket],
                      ].map(([key, value]) => (
                        <div className="detail-row" key={key}>
                          <span>{key}</span>
                          <code>{value}</code>
                        </div>
                      ))
                    : "Select an object to inspect its properties."}
                </div>
              )}
              {tab === "preview" && <div className="inspector-empty">Preview is not available in this preview build.</div>}
              {tab === "events" && <div className="inspector-empty">No events for this object.</div>}
            </div>
          </>
        )}
      </main>

      <footer className="transfer-footer">
        <div className="transfer-counts">
          <button type="button" className="transfer-filter">Running (0)</button>
          <button type="button" className="transfer-filter">Queued (0)</button>
          <button type="button" className="transfer-filter">Stopped</button>
          <button type="button" className="transfer-filter">Failed</button>
        </div>
        <span className="transfer-summary">All (0) · 0 MB / 0 MB · 0 MB/s · 00:00:00</span>
        <div className="transfer-actions">
          <button type="button" disabled>
            <Icon name="play" /> Start All
          </button>
          <button type="button" disabled>
            <Icon name="stop" /> Stop All
          </button>
          <button type="button" disabled>
            <Icon name="cancel" /> Cancel All
          </button>
        </div>
      </footer>

      {dialog && (
        <AccountDialog
          account={dialog.account}
          onClose={() => setDialog(null)}
          onSaved={(saved) => {
            setDialog(null);
            void loadAccounts().then(() => setAccountId(saved.id));
          }}
        />
      )}
    </div>
  );
}
