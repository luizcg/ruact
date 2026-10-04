// Story 18-1 — the stream React's Flight client reads, with its failures
// labelled.
//
// When a response ends before every row arrived (the server raised while
// streaming a deferred child, a proxy timed out, the network dropped), React's
// client fails the rows still pending — with "Connection closed." in its
// development build and a minified "#412" in production, or with whatever the
// network threw. The Suspense boundary must recognise all of these as the
// transport's, not as a crash in the app's components. So the stream ends with
// an error carrying a digest the boundary knows; for a complete response that
// changes nothing, since the client only fails rows still pending. A
// superseded navigation's AbortError passes through as it is.
import { isAbort } from "./suspense-boundary.js";

export const CONNECTION_CLOSED_DIGEST = "ruact:connection-closed";

function closed(cause) {
  const error = new Error("the response ended before the whole page arrived", cause ? { cause } : undefined);
  error.digest = CONNECTION_CLOSED_DIGEST;
  return error;
}

export function labelledStream(stream) {
  const reader = stream.getReader();
  return new ReadableStream({
    async pull(controller) {
      let result;
      try {
        result = await reader.read();
      } catch (error) {
        controller.error(isAbort(error) ? error : closed(error));
        return;
      }
      if (result.done) controller.error(closed());
      else controller.enqueue(result.value);
    },
    cancel(reason) {
      return reader.cancel(reason);
    },
  });
}
