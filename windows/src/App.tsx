import { useCallback, useEffect, useMemo, useState, type FormEvent } from "react";
import { open, save } from "@tauri-apps/plugin-dialog";
import { api } from "./api";
import type { Account, AccountInput, Bucket, ListPage, ObjectEntry } from "./types";

function joinKey(prefix: string, name: string) {
  return `${prefix}${name}`;
}

function formatSize(bytes: number | null) {
  if (bytes === null) return "—";
  if (bytes < 1024) return `${bytes} B`;
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
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function FolderIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M3.5 6.5h6l2 2h9v9.5a2 2 0 0 1-2 2h-15a2 2 0 0 1-2-2V8.5a2 2 0 0 1 2-2Z" />
    </svg>
  );
}

function FileIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M6 3.5h7l5 5v12H6z" />
      <path d="M13 3.5v5h5" />
    </svg>
  );
}

function BucketIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M4 7h16l-1.5 12h-13z" />
      <path d="M7 4h10M8 11h8" />
    </svg>
  );
}

function UploadIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 16V4m0 0L7 9m5-5 5 5" />
      <path d="M4 15v5h16v-5" />
    </svg>
  );
}

function DownloadIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 4v12m0 0 5-5m-5 5-5-5" />
      <path d="M4 19h16" />
    </svg>
  );
}

function PlusIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 5v14M5 12h14" />
    </svg>
  );
}

function RefreshIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M20 11a8 8 0 1 0-2.3 5.7" />
      <path d="M20 5v6h-6" />
    </svg>
  );
}

function TrashIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M4 7h16M9 7V4h6v3M7 7l1 13h8l1-13M10 11v5M14 11v5" />
    </svg>
  );
}

function SettingsIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r="3" />
      <path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M18.4 5.6l-2.1 2.1M7.7 16.3l-2.1 2.1" />
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
  const [error, setError] = useState("");

  const update = <K extends keyof AccountInput>(key: K, value: AccountInput[K]) =>
    setForm((current) => ({ ...current, [key]: value }));

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setError("");
    if (!form.name.trim() || !form.accessKeyId.trim() || !form.region.trim()) {
      setError("Name, access key ID, and region are required.");
      return;
    }
    if (!account && !form.secretAccessKey?.trim()) {
      setError("Secret access key is required for a new account.");
      return;
    }
    setSaving(true);
    try {
      const saved = await api.saveAccount({
        ...form,
        name: form.name.trim(),
        accessKeyId: form.accessKeyId.trim(),
        region: form.region.trim(),
        endpoint: form.endpoint?.trim() || undefined,
        bucket: form.bucket?.trim() || undefined,
        secretAccessKey: form.secretAccessKey?.trim() || undefined,
      });
      onSaved(saved);
    } catch (nextError) {
      setError(errorMessage(nextError));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="dialog-backdrop" role="presentation" onMouseDown={onClose}>
      <form className="dialog" onSubmit={submit} onMouseDown={(event) => event.stopPropagation()}>
        <div className="dialog-heading">
          <div>
            <h2>{account ? "Edit account" : "Add storage account"}</h2>
            <p>Secrets are stored in Windows Credential Manager.</p>
          </div>
          <button className="icon-button" type="button" onClick={onClose} aria-label="Close">
            ×
          </button>
        </div>

        <label>
          Display name
          <input
            autoFocus
            value={form.name}
            onChange={(event) => update("name", event.target.value)}
            placeholder="Production storage"
          />
        </label>

        <div className="field-row">
          <label>
            Access key ID
            <input
              value={form.accessKeyId}
              onChange={(event) => update("accessKeyId", event.target.value)}
              placeholder="AKIA…"
              autoComplete="off"
            />
          </label>
          <label>
            Secret access key
            <input
              type="password"
              value={form.secretAccessKey}
              onChange={(event) => update("secretAccessKey", event.target.value)}
              placeholder={account ? "Leave blank to keep current" : "Required"}
              autoComplete="new-password"
            />
          </label>
        </div>

        <div className="field-row">
          <label>
            Region
            <input
              value={form.region}
              onChange={(event) => update("region", event.target.value)}
              placeholder="us-east-1"
            />
          </label>
          <label>
            Bucket-scoped key (optional)
            <input
              value={form.bucket}
              onChange={(event) => update("bucket", event.target.value)}
              placeholder="my-bucket"
            />
          </label>
        </div>

        <label>
          Endpoint (S3-compatible providers only)
          <input
            value={form.endpoint}
            onChange={(event) => update("endpoint", event.target.value)}
            placeholder="https://s3.example.com"
          />
        </label>

        <label className="check-row">
          <input
            type="checkbox"
            checked={form.pathStyle}
            onChange={(event) => update("pathStyle", event.target.checked)}
          />
          Use path-style addressing
        </label>

        {error && <div className="form-error">{error}</div>}

        <div className="dialog-actions">
          <button type="button" className="button secondary" onClick={onClose}>
            Cancel
          </button>
          <button type="submit" className="button primary" disabled={saving}>
            {saving ? "Saving…" : "Save account"}
          </button>
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
  const [selected, setSelected] = useState<ObjectEntry | null>(null);
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
    let cancelled = false;
    setBuckets([]);
    setBucket("");
    setPrefix("");
    setPage(null);
    setSelected(null);
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
        setSelected(null);
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

  const activeBucket = buckets.find((item) => item.name === bucket);

  const openFolder = (entry: ObjectEntry) => {
    setPrefix(entry.key.endsWith("/") ? entry.key : `${entry.key}/`);
  };

  const refresh = () => {
    setRefreshTick((value) => value + 1);
    setSelected(null);
  };

  const uploadFiles = async () => {
    if (!accountId || !bucket || busy) return;
    const picked = await open({
      multiple: true,
      title: "Upload files",
    });
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

  const downloadObject = async (entry: ObjectEntry) => {
    if (!accountId || !bucket || entry.kind !== "object" || busy) return;
    const destination = await save({
      title: "Download object",
      defaultPath: entry.name,
    });
    if (!destination) return;

    setBusy(true);
    setError("");
    try {
      await api.downloadObject(accountId, bucket, entry.key, destination);
    } catch (nextError) {
      setError(errorMessage(nextError));
    } finally {
      setBusy(false);
    }
  };

  const downloadSelected = async () => {
    if (selected) await downloadObject(selected);
  };

  const deleteSelected = async () => {
    if (!accountId || !bucket || !selected || busy) return;
    const label = selected.kind === "folder" ? `folder “${selected.name}”` : `“${selected.name}”`;
    if (!window.confirm(`Delete ${label}? This cannot be undone.`)) return;

    setBusy(true);
    setError("");
    try {
      await api.deleteObject(accountId, bucket, selected.key);
      refresh();
    } catch (nextError) {
      setError(errorMessage(nextError));
    } finally {
      setBusy(false);
    }
  };

  const createFolder = async () => {
    if (!accountId || !bucket || busy) return;
    const name = window.prompt("New folder name");
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

  const loadMore = async () => {
    if (!accountId || !bucket || !page?.nextToken || loadingObjects) return;
    setLoadingObjects(true);
    try {
      const nextPage = await api.listObjects(accountId, bucket, prefix, page.nextToken);
      setPage((current) =>
        current
          ? {
              ...current,
              entries: [...current.entries, ...nextPage.entries],
              nextToken: nextPage.nextToken,
            }
          : nextPage,
      );
    } catch (nextError) {
      setError(errorMessage(nextError));
    } finally {
      setLoadingObjects(false);
    }
  };

  if (loadingAccounts) {
    return <div className="boot">Loading accounts…</div>;
  }

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <div className="brand-mark">
            <BucketIcon />
          </div>
          <div>
            <strong>Bucket Manager</strong>
            <span>Windows preview</span>
          </div>
        </div>

        <div className="sidebar-section">
          <div className="section-title">
            <span>Accounts</span>
            <button
              className="icon-button"
              type="button"
              aria-label="Add account"
              onClick={() => setDialog({})}
            >
              <PlusIcon />
            </button>
          </div>
          {accounts.length === 0 ? (
            <button className="empty-action" type="button" onClick={() => setDialog({})}>
              Add your first account
            </button>
          ) : (
            <div className="account-list">
              {accounts.map((account) => (
                <div
                  key={account.id}
                  role="button"
                  tabIndex={0}
                  className={`account-row ${account.id === accountId ? "active" : ""}`}
                  onClick={() => setAccountId(account.id)}
                  onKeyDown={(event) => {
                    if (event.key === "Enter" || event.key === " ") {
                      event.preventDefault();
                      setAccountId(account.id);
                    }
                  }}
                >
                  <span className="account-avatar">{account.name.slice(0, 1).toUpperCase()}</span>
                  <span className="account-copy">
                    <strong>{account.name}</strong>
                    <small>{account.endpoint || account.region}</small>
                  </span>
                  <button
                    type="button"
                    className="icon-button subtle"
                    aria-label={`Edit ${account.name}`}
                    onClick={(event) => {
                      event.stopPropagation();
                      setDialog({ account });
                    }}
                  >
                    <SettingsIcon />
                  </button>
                </div>
              ))}
            </div>
          )}
        </div>

        <div className="sidebar-section buckets-section">
          <div className="section-title">
            <span>Buckets</span>
            <span className="count">{buckets.length}</span>
          </div>
          {loadingBuckets ? (
            <div className="sidebar-note">Loading buckets…</div>
          ) : buckets.length === 0 ? (
            <div className="sidebar-note">{accountId ? "No buckets found." : "Select an account."}</div>
          ) : (
            <div className="bucket-list">
              {buckets.map((item) => (
                <button
                  type="button"
                  key={item.name}
                  className={`bucket-row ${item.name === bucket ? "active" : ""}`}
                  onClick={() => {
                    setBucket(item.name);
                    setPrefix("");
                  }}
                >
                  <BucketIcon />
                  <span>{item.name}</span>
                </button>
              ))}
            </div>
          )}
        </div>

        <div className="sidebar-footer">
          <span>{activeAccount?.region ?? "No account"}</span>
          {activeAccount?.pathStyle && <span>Path-style</span>}
        </div>
      </aside>

      <main className="main">
        <header className="toolbar">
          <div className="breadcrumbs">
            <button type="button" onClick={() => setPrefix("")} disabled={!bucket}>
              {bucket || "Objects"}
            </button>
            {breadcrumb.map((item) => (
              <button type="button" key={item.prefix} onClick={() => setPrefix(item.prefix)}>
                {item.name}
              </button>
            ))}
          </div>
          <div className="toolbar-actions">
            <button className="button secondary" type="button" onClick={createFolder} disabled={!bucket || busy}>
              <PlusIcon />
              Folder
            </button>
            <button className="button secondary" type="button" onClick={uploadFiles} disabled={!bucket || busy}>
              <UploadIcon />
              Upload
            </button>
            <button
              className="button secondary"
              type="button"
              onClick={downloadSelected}
              disabled={!selected || selected.kind !== "object" || busy}
            >
              <DownloadIcon />
              Download
            </button>
            <button
              className="button secondary danger"
              type="button"
              onClick={deleteSelected}
              disabled={!selected || busy}
            >
              <TrashIcon />
              Delete
            </button>
            <button className="icon-button" type="button" onClick={refresh} aria-label="Refresh">
              <RefreshIcon />
            </button>
          </div>
        </header>

        {error && (
          <div className="error-banner">
            <span>{error}</span>
            <button type="button" onClick={() => setError("")}>
              Dismiss
            </button>
          </div>
        )}

        {!accountId ? (
          <div className="empty-state">
            <div className="empty-icon">
              <BucketIcon />
            </div>
            <h2>Add a storage account</h2>
            <p>Connect Amazon S3 or any S3-compatible endpoint to browse buckets and objects.</p>
            <button className="button primary" type="button" onClick={() => setDialog({})}>
              Add account
            </button>
          </div>
        ) : !bucket ? (
          <div className="empty-state">
            <h2>Select a bucket</h2>
            <p>Choose a bucket in the sidebar to browse its contents.</p>
          </div>
        ) : (
          <section className="content">
            <div className="content-heading">
              <div>
                <h1>{activeBucket?.name ?? bucket}</h1>
                <p>{prefix ? `Prefix: ${prefix}` : "Bucket root"}</p>
              </div>
              <div className="content-meta">
                {loadingObjects ? "Loading…" : `${page?.entries.length ?? 0} items`}
                {selected && <span>{selected.name} selected</span>}
              </div>
            </div>

            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Name</th>
                    <th className="size-column">Size</th>
                    <th>Last modified</th>
                    <th>Storage class</th>
                  </tr>
                </thead>
                <tbody>
                  {loadingObjects && !page ? (
                    <tr>
                      <td colSpan={4} className="table-message">
                        Loading objects…
                      </td>
                    </tr>
                  ) : page?.entries.length === 0 ? (
                    <tr>
                      <td colSpan={4} className="table-message">
                        This folder is empty.
                      </td>
                    </tr>
                  ) : (
                    page?.entries.map((entry) => (
                      <tr
                        key={`${entry.kind}:${entry.key}`}
                        className={selected?.key === entry.key ? "selected" : ""}
                        onClick={() => setSelected(entry)}
                        onDoubleClick={() => {
                          if (entry.kind === "folder") openFolder(entry);
                          else void downloadObject(entry);
                        }}
                      >
                        <td>
                          <span className="name-cell">
                            <span className={`file-icon ${entry.kind}`}>
                              {entry.kind === "folder" ? <FolderIcon /> : <FileIcon />}
                            </span>
                            <span>{entry.name}</span>
                          </span>
                        </td>
                        <td className="size-column">{formatSize(entry.size)}</td>
                        <td>{formatDate(entry.lastModified)}</td>
                        <td>{entry.storageClass || "—"}</td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>

            {page?.nextToken && (
              <div className="load-more">
                <button className="button secondary" type="button" onClick={loadMore} disabled={loadingObjects}>
                  {loadingObjects ? "Loading…" : "Load more"}
                </button>
              </div>
            )}
          </section>
        )}

        <footer className="statusbar">
          <span>{activeAccount ? `${activeAccount.name} · ${activeAccount.region}` : "No account"}</span>
          <span>{busy ? "Working…" : page ? `${page.entries.length} loaded` : ""}</span>
        </footer>
      </main>

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
