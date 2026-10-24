import { useEffect, useMemo, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { save } from "@tauri-apps/plugin-dialog";
import { api } from "./api";
import type { LogFilter, LogRecord, LoggingSettings, RequestMetric } from "./types";
import { applyAppearance, initAppearance, type Appearance } from "./theme";
import "./logs.css";

type Tab = "logs" | "statistics" | "settings";

const categories = [
  ["", "All categories"],
  ["audit", "Audit only"],
  ["ui", "UI"],
  ["network", "Network"],
  ["transfer", "Transfer"],
  ["settings", "Settings"],
];

const levels = [
  ["", "All levels"],
  ["trace", "Trace+"],
  ["debug", "Debug+"],
  ["info", "Info+"],
  ["warning", "Warning+"],
  ["error", "Error+"],
];

function formatTime(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  const pad = (part: number) => String(part).padStart(2, "0");
  return `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(
    date.getMinutes(),
  )}:${pad(date.getSeconds())}`;
}

function titleCase(value: string) {
  return value ? value.charAt(0).toUpperCase() + value.slice(1) : value;
}

function formatBytes(bytes: number) {
  if (!bytes) return "0 bytes";
  const units = ["bytes", "KB", "MB", "GB", "TB"];
  const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  const value = bytes / 1024 ** index;
  return `${value >= 100 || index === 0 ? value.toFixed(0) : value.toFixed(1)} ${units[index]}`;
}

function tabFrom(value: string | null): Tab {
  return value === "statistics" || value === "settings" ? value : "logs";
}

export default function LogsApp() {
  const [tab, setTab] = useState<Tab>("logs");
  const [records, setRecords] = useState<LogRecord[]>([]);
  const [selected, setSelected] = useState<LogRecord | null>(null);
  const [query, setQuery] = useState("");
  const [logAccount, setLogAccount] = useState("");
  const [level, setLevel] = useState("");
  const [category, setCategory] = useState("");
  const [live, setLive] = useState(true);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [metrics, setMetrics] = useState<RequestMetric[]>([]);
  const [statsAccount, setStatsAccount] = useState("");
  const [statsRange, setStatsRange] = useState<"session" | "all">("session");
  const [settings, setSettings] = useState<LoggingSettings | null>(null);
  const [settingsStatus, setSettingsStatus] = useState("");
  const [saving, setSaving] = useState(false);

  const filter = useMemo<LogFilter>(
    () => ({
      limit: 5000,
      level: level || undefined,
      category: category || undefined,
      query: query.trim() || undefined,
      accountId: logAccount || undefined,
    }),
    [level, category, query, logAccount],
  );

  async function loadLogs() {
    if (loading) return;
    setLoading(true);
    try {
      const next = await api.getLogs(filter);
      setRecords(next);
      setSelected((current) => (current && next.some((record) => record.timestamp === current.timestamp && record.event === current.event) ? current : null));
      setError("");
    } catch (loadError) {
      setError(String(loadError));
    } finally {
      setLoading(false);
    }
  }

  async function loadStats() {
    try {
      setMetrics(await api.getStatistics());
      setError("");
    } catch (loadError) {
      setError(String(loadError));
    }
  }

  async function loadSettings() {
    try {
      setSettings(await api.getLoggingSettings());
      setError("");
    } catch (loadError) {
      setError(String(loadError));
    }
  }

  useEffect(() => {
    void initAppearance();
    let active = true;
    let unlistenTheme: (() => void) | undefined;
    let unlistenTab: (() => void) | undefined;
    void api.takeLogsTab().then((value) => {
      if (active && value) setTab(tabFrom(value));
    });
    void listen<Appearance>("appearance-changed", (event) => applyAppearance(event.payload)).then((fn) => {
      if (active) unlistenTheme = fn;
      else fn();
    });
    void listen<string>("logs-tab", (event) => {
      if (active) setTab(tabFrom(event.payload));
    }).then((fn) => {
      if (active) unlistenTab = fn;
      else fn();
    });
    return () => {
      active = false;
      unlistenTheme?.();
      unlistenTab?.();
    };
  }, []);

  useEffect(() => {
    void loadLogs();
  }, [filter]);

  useEffect(() => {
    if (!live) return;
    const timer = window.setInterval(() => {
      if (tab === "logs") void loadLogs();
    }, 2000);
    return () => window.clearInterval(timer);
  }, [live, tab, filter, loading]);

  useEffect(() => {
    if (tab === "statistics") void loadStats();
    if (tab === "settings") void loadSettings();
  }, [tab]);

  const accounts = useMemo(() => {
    const names = new Map<string, string>();
    for (const record of records) {
      if (record.accountId && record.accountName) names.set(record.accountId, record.accountName);
    }
    return [...names.entries()];
  }, [records]);

  const filteredMetrics = useMemo(
    () =>
      metrics.filter(
        (metric) =>
          (!statsAccount || metric.accountId === statsAccount) &&
          (statsRange === "all" || metric.sessionRequests > 0),
      ),
    [metrics, statsAccount, statsRange],
  );

  const statsSummary = useMemo(() => {
    const requestCount = (metric: RequestMetric) =>
      statsRange === "session" ? metric.sessionRequests : metric.requests;
    const total = filteredMetrics.reduce((sum, metric) => sum + requestCount(metric), 0);
    const list = filteredMetrics
      .filter((metric) => metric.operation === "ListObjectsV2")
      .reduce((sum, metric) => sum + requestCount(metric), 0);
    const failures = filteredMetrics.reduce((sum, metric) => sum + metric.failures, 0);
    const bytes = filteredMetrics.reduce((sum, metric) => sum + metric.bytes, 0);
    return `${total} requests · ${list} list requests · ${failures} errors · ${formatBytes(bytes)} transferred`;
  }, [filteredMetrics, statsRange]);

  async function clearLogs() {
    if (!window.confirm("Clear diagnostic logs? Audit records are retained.")) return;
    try {
      await api.clearDiagnostics();
      setSettingsStatus("Diagnostic logs cleared.");
      await loadLogs();
    } catch (clearError) {
      setError(String(clearError));
    }
  }

  async function exportLogs() {
    const destination = await save({ defaultPath: "bucket-manager-logs.jsonl" });
    if (!destination) return;
    try {
      const count = await api.exportLogs(destination, filter);
      setSettingsStatus(`${count} records exported.`);
    } catch (exportError) {
      setError(String(exportError));
    }
  }

  async function saveSettings() {
    if (!settings) return;
    setSaving(true);
    try {
      await api.saveLoggingSettings(settings);
      setSettingsStatus("Saved. Audit logging remains enabled.");
      setSettings(await api.getLoggingSettings());
    } catch (saveError) {
      setError(String(saveError));
    } finally {
      setSaving(false);
    }
  }

  const currentTab = tab;

  return (
    <div className="logs-shell">
      <header className="logs-header">
        <div className="segmented" role="tablist" aria-label="Logs sections">
          {(["logs", "statistics", "settings"] as const).map((item) => (
            <button
              key={item}
              role="tab"
              aria-selected={currentTab === item}
              className={currentTab === item ? "selected" : ""}
              onClick={() => setTab(item)}
            >
              {item === "logs" ? "Logs" : item === "statistics" ? "Statistics" : "Settings"}
            </button>
          ))}
        </div>
      </header>

      {error && (
        <div className="logs-error" role="alert">
          {error}
          <button onClick={() => setError("")}>Dismiss</button>
        </div>
      )}

      {currentTab === "logs" && (
        <section className="logs-section">
          <div className="logs-toolbar">
            <input
              className="logs-search"
              placeholder="Search logs"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              aria-label="Search logs"
            />
            <select value={level} onChange={(event) => setLevel(event.target.value)} aria-label="Minimum log level">
              {levels.map(([value, label]) => (
                <option key={value} value={value}>
                  {label}
                </option>
              ))}
            </select>
            <select value={category} onChange={(event) => setCategory(event.target.value)} aria-label="Log category">
              {categories.map(([value, label]) => (
                <option key={value} value={value}>
                  {label}
                </option>
              ))}
            </select>
            <select value={logAccount} onChange={(event) => setLogAccount(event.target.value)} aria-label="Log account">
              <option value="">All accounts</option>
              {accounts.map(([id, name]) => (
                <option key={id} value={id}>
                  {name}
                </option>
              ))}
            </select>
            <label className="inline-check">
              <input type="checkbox" checked={live} onChange={(event) => setLive(event.target.checked)} />
              Live
            </label>
            <button className="button" onClick={() => void loadLogs()} disabled={loading}>
              Refresh
            </button>
          </div>

          <div className="logs-table-wrap">
            <table className="logs-table">
              <thead>
                <tr>
                  <th>Time</th>
                  <th>Level</th>
                  <th>Category</th>
                  <th>Account</th>
                  <th>Operation</th>
                  <th>Bucket / Key</th>
                  <th>Status</th>
                  <th>Message</th>
                </tr>
              </thead>
              <tbody>
                {records.map((record, index) => (
                  <tr
                    key={`${record.timestamp}-${record.event}-${index}`}
                    className={selected === record ? "selected" : ""}
                    onClick={() => setSelected(record)}
                  >
                    <td className="mono">{formatTime(record.timestamp)}</td>
                    <td className={`level ${record.level}`}>{titleCase(record.level)}</td>
                    <td>{titleCase(record.category)}</td>
                    <td>{record.accountName || "—"}</td>
                    <td>{record.operation || record.event}</td>
                    <td className="truncate">{[record.bucket, record.key].filter(Boolean).join(" / ") || "—"}</td>
                    <td>{record.outcome || "—"}</td>
                    <td className="truncate">{record.message}</td>
                  </tr>
                ))}
                {!records.length && (
                  <tr>
                    <td colSpan={8} className="logs-empty">
                      {loading ? "Loading log records…" : "No log records match the current filters."}
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>

          <div className="log-detail">
            <h2>Details</h2>
            <pre>{selected ? JSON.stringify(selected, null, 2) : "Select a log record to inspect it."}</pre>
          </div>

          <footer className="logs-footer">
            <span>{records.length} {records.length === 1 ? "record" : "records"}</span>
            <div>
              <button className="button" onClick={() => void api.revealLogs()}>Reveal Logs</button>
              <button className="button" onClick={clearLogs}>Clear Diagnostics</button>
              <button className="button" onClick={exportLogs}>Export</button>
            </div>
          </footer>
        </section>
      )}

      {currentTab === "statistics" && (
        <section className="logs-section">
          <div className="logs-toolbar">
            <select value={statsAccount} onChange={(event) => setStatsAccount(event.target.value)} aria-label="Statistics account">
              <option value="">All accounts</option>
              {[...new Set(metrics.map((metric) => metric.accountId))].map((id) => {
                const metric = metrics.find((item) => item.accountId === id);
                return (
                  <option key={id} value={id}>
                    {metric?.accountName || id}
                  </option>
                );
              })}
            </select>
            <select value={statsRange} onChange={(event) => setStatsRange(event.target.value as "session" | "all")} aria-label="Statistics range">
              <option value="session">Session</option>
              <option value="all">All time</option>
            </select>
            <button className="button" onClick={() => void loadStats()}>Refresh</button>
            <button
              className="button"
              onClick={() => {
                if (window.confirm("Clear request statistics? Audit records are retained.")) {
                  void api.clearStatistics().then(loadStats);
                }
              }}
            >
              Clear Statistics
            </button>
          </div>
          <div className="logs-table-wrap">
            <table className="logs-table stats-table">
              <thead>
                <tr>
                  <th>Account</th>
                  <th>Bucket</th>
                  <th>Operation</th>
                  <th>Requests</th>
                  <th>Errors</th>
                  <th>Avg ms</th>
                  <th>Bytes</th>
                  <th>Last Used</th>
                </tr>
              </thead>
              <tbody>
                {filteredMetrics.map((metric) => {
                  const requests = statsRange === "session" ? metric.sessionRequests : metric.requests;
                  return (
                    <tr key={`${metric.accountId}-${metric.bucket}-${metric.operation}`}>
                      <td>{metric.accountName}</td>
                      <td>{metric.bucket || "—"}</td>
                      <td>{metric.operation}</td>
                      <td>{requests}</td>
                      <td>{metric.failures}</td>
                      <td>{requests ? (metric.totalMs / requests).toFixed(1) : "0.0"}</td>
                      <td>{formatBytes(metric.bytes)}</td>
                      <td className="mono">{formatTime(metric.lastUsed)}</td>
                    </tr>
                  );
                })}
                {!filteredMetrics.length && (
                  <tr>
                    <td colSpan={8} className="logs-empty">
                      No statistics for this range yet.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
          <footer className="logs-footer stats-summary">{statsSummary}</footer>
        </section>
      )}

      {currentTab === "settings" && settings && (
        <section className="logs-section settings-view">
          <h2>Logging</h2>
          <label className="inline-check">
            <input
              type="checkbox"
              checked={settings.diagnosticsEnabled}
              onChange={(event) => setSettings({ ...settings, diagnosticsEnabled: event.target.checked })}
            />
            Enable diagnostic request and UI logging
          </label>
          <div className="settings-row">
            <label>Minimum level</label>
            <select
              value={settings.minimumLevel}
              onChange={(event) => setSettings({ ...settings, minimumLevel: event.target.value })}
            >
              {levels.slice(1).map(([value, label]) => (
                <option key={value} value={value}>
                  {label.replace("+", "")}
                </option>
              ))}
            </select>
          </div>
          <div className="settings-categories">
            <span>Diagnostic categories</span>
            <div>
              {[
                ["ui", "UI"],
                ["network", "Network"],
                ["transfer", "Transfer"],
                ["settings", "Settings"],
              ].map(([value, label]) => (
                <label key={value} className="inline-check">
                  <input
                    type="checkbox"
                    checked={settings.enabledCategories.includes(value)}
                    onChange={(event) =>
                      setSettings({
                        ...settings,
                        enabledCategories: event.target.checked
                          ? [...settings.enabledCategories, value]
                          : settings.enabledCategories.filter((category) => category !== value),
                      })
                    }
                  />
                  {label}
                </label>
              ))}
            </div>
          </div>
          <div className="settings-row">
            <label>Diagnostics retention</label>
            <select
              value={settings.diagnosticRetentionDays}
              onChange={(event) => setSettings({ ...settings, diagnosticRetentionDays: Number(event.target.value) })}
            >
              {[7, 14, 30, 60].map((days) => (
                <option key={days} value={days}>
                  {days} days
                </option>
              ))}
            </select>
          </div>
          <div className="settings-row">
            <label>Audit retention</label>
            <select
              value={settings.auditRetentionDays}
              onChange={(event) => setSettings({ ...settings, auditRetentionDays: Number(event.target.value) })}
            >
              {[30, 90, 180, 365].map((days) => (
                <option key={days} value={days}>
                  {days} days
                </option>
              ))}
            </select>
          </div>
          <label className="inline-check">
            <input
              type="checkbox"
              checked={settings.includeObjectKeys}
              onChange={(event) => setSettings({ ...settings, includeObjectKeys: event.target.checked })}
            />
            Include object keys in logs
          </label>
          <p className="settings-note">
            Audit logging is always on. Credentials, authorization headers, and signatures are never
            logged. Diagnostic logging is off by default.
          </p>
          <div className="settings-actions">
            <button className="button primary" onClick={() => void saveSettings()} disabled={saving}>
              {saving ? "Saving…" : "Save Logging Settings"}
            </button>
            <button className="button" onClick={() => void api.revealLogs()}>Reveal Logs</button>
          </div>
          <p className="settings-status">{settingsStatus || "Unsaved changes."}</p>
        </section>
      )}

      <footer className="logs-window-footer">
        <span>Logs &amp; Statistics</span>
        <span>Audit records are retained unless you clear diagnostics.</span>
      </footer>
    </div>
  );
}
