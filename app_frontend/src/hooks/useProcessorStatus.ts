import { useCallback, useEffect, useRef, useState } from "react";
import { fetchStats } from "@/queries/api";

export const useProcessorStatus = () => {
  const [isProcessing, setIsProcessing] = useState(false);
  const eventSourceRef = useRef<EventSource | null>(null);
  const reconnectTimeoutRef = useRef<number | null>(null);
  const reconnectAttemptsRef = useRef(0);
  const MAX_RECONNECT_ATTEMPTS = 5;

  // Fetch initial status
  const fetchInitialStatus = useCallback(async () => {
    const stats = await fetchStats();
    // Extract isProcessing status from the stats response
    setIsProcessing(stats.is_processing || false);
  }, []);

  const connect = useCallback(() => {
    // Clear any existing reconnection timeout
    if (reconnectTimeoutRef.current) {
      clearTimeout(reconnectTimeoutRef.current);
      reconnectTimeoutRef.current = null;
    }

    // Close existing connection
    if (eventSourceRef.current) {
      eventSourceRef.current.close();
    }

    const es = new EventSource("/api/processor-status");

    es.addEventListener("processing_started", () => {
      setIsProcessing(true);
      reconnectAttemptsRef.current = 0; // Reset reconnect attempts on successful event
    });

    es.addEventListener("processing_finished", () => {
      setIsProcessing(false);
    });

    es.addEventListener("error", () => {
      console.error("Processor status SSE connection error");
      setIsProcessing(false);

      // Attempt reconnection with exponential backoff
      if (reconnectAttemptsRef.current < MAX_RECONNECT_ATTEMPTS) {
        const delay = Math.min(1000 * 2 ** reconnectAttemptsRef.current, 30000);
        reconnectAttemptsRef.current++;

        console.log(
          `Attempting to reconnect in ${delay}ms (attempt ${reconnectAttemptsRef.current}/${MAX_RECONNECT_ATTEMPTS})`,
        );

        reconnectTimeoutRef.current = setTimeout(() => {
          connect();
        }, delay);
      } else {
        console.error("Max reconnection attempts reached. Giving up.");
      }
    });

    es.onopen = () => {
      reconnectAttemptsRef.current = 0;
    };

    eventSourceRef.current = es;
  }, []);

  useEffect(() => {
    // Fetch initial status and then connect to SSE
    fetchInitialStatus().then(() => {
      connect();
    });

    return () => {
      if (eventSourceRef.current) {
        eventSourceRef.current.close();
      }
      if (reconnectTimeoutRef.current) {
        clearTimeout(reconnectTimeoutRef.current);
      }
    };
  }, [connect, fetchInitialStatus]);

  return { isProcessing };
};
