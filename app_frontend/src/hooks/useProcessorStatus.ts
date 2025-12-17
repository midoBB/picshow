import { useCallback, useEffect, useState } from "react";

export const useProcessorStatus = () => {
	const [isProcessing, setIsProcessing] = useState(false);
	const [eventSource, setEventSource] = useState<EventSource | null>(null);

	const connect = useCallback(() => {
		const es = new EventSource("/api/processor-status");

		es.addEventListener("processing_started", () => {
			setIsProcessing(true);
		});

		es.addEventListener("processing_finished", () => {
			setIsProcessing(false);
		});

		es.addEventListener("error", () => {
			console.error("Processor status SSE connection error");
			setIsProcessing(false);
		});

		setEventSource(es);
	}, []);

	useEffect(() => {
		connect();

		return () => {
			if (eventSource) {
				eventSource.close();
			}
		};
	}, [connect]);

	return { isProcessing };
};
