import React from "react";
import ReactDOM from "react-dom/client";
import { getCurrentWindow } from "@tauri-apps/api/window";
import App from "./App";
import LogsApp from "./LogsApp";
import "./styles.css";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    {getCurrentWindow().label === "logs" ? <LogsApp /> : <App />}
  </React.StrictMode>,
);
