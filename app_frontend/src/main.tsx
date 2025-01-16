import React from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import ReactDOM from "react-dom/client";
import App from "@/App.tsx";
import "@/index.css";
import { NuqsAdapter } from "nuqs/adapters/react";

const queryClient = new QueryClient();

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <NuqsAdapter>
      <QueryClientProvider client={queryClient}>
        <App />
      </QueryClientProvider>
    </NuqsAdapter>
  </React.StrictMode>,
);
