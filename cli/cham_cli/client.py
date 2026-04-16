"""HTTP client for the Cham REST API."""

import sys
from typing import Any, Optional

import httpx


class ChamClient:
    """Thin wrapper around httpx for communicating with the Cham server."""

    def __init__(self, base_url: str, api_key: str = ""):
        self.base_url = base_url.rstrip("/")
        headers = {}
        if api_key:
            headers["authorization"] = f"Bearer {api_key}"
        self._client = httpx.Client(
            base_url=self.base_url,
            headers=headers,
            timeout=30.0,
        )

    def health(self) -> dict:
        """Check server health via GET /health."""
        return self._request("GET", "/health")

    def submit_item(self, url: str, tags: Optional[list[str]] = None) -> dict:
        """Submit a URL for archiving via POST /api/v1/items."""
        payload: dict[str, Any] = {"url": url}
        if tags:
            payload["tags"] = tags
        return self._request("POST", "/api/v1/items", json=payload)

    def list_items(
        self,
        status: Optional[str] = None,
        content_type: Optional[str] = None,
        tag: Optional[str] = None,
    ) -> list[dict]:
        """List items via GET /api/v1/items."""
        params: dict[str, str] = {}
        if status:
            params["status"] = status
        if content_type:
            params["content_type"] = content_type
        if tag:
            params["tag"] = tag
        result = self._request("GET", "/api/v1/items", params=params)
        if isinstance(result, dict) and "items" in result:
            return result["items"]
        if isinstance(result, list):
            return result
        return []

    def get_item(self, id_or_slug: str) -> dict:
        """Get a single item via GET /api/v1/items/:id_or_slug."""
        return self._request("GET", f"/api/v1/items/{id_or_slug}")

    def reprocess_item(
        self,
        id_or_slug: str,
        retry_failed: bool = False,
        invalidate: Optional[list[str]] = None,
    ) -> dict:
        """Reprocess an item via POST /api/v1/items/:id/reprocess."""
        payload: dict[str, Any] = {}
        if retry_failed:
            payload["retry_failed"] = True
        if invalidate:
            payload["invalidate"] = invalidate
        return self._request("POST", f"/api/v1/items/{id_or_slug}/reprocess", json=payload)

    def delete_item(self, id_or_slug: str, keep_files: bool = False) -> dict:
        """Delete an item via DELETE /api/v1/items/:id."""
        params = {}
        if keep_files:
            params["keep_files"] = "true"
        return self._request("DELETE", f"/api/v1/items/{id_or_slug}", params=params)

    def cancel_item(self, id_or_slug: str) -> dict:
        """Cancel an item via POST /api/v1/items/:id/cancel."""
        return self._request("POST", f"/api/v1/items/{id_or_slug}/cancel")

    def retry_item(
        self, id_or_slug: str, from_stage: Optional[str] = None
    ) -> dict:
        """Retry a failed item via POST /api/v1/items/:id/retry."""
        payload: dict[str, Any] = {}
        if from_stage:
            payload["from_stage"] = from_stage
        return self._request("POST", f"/api/v1/items/{id_or_slug}/retry", json=payload)

    def stream_events(self, id_or_slug: str):
        """Stream SSE events for an item. Yields (event_type, data_dict) tuples."""
        url = f"{self.base_url}/api/v1/items/{id_or_slug}/events"
        headers = dict(self._client.headers)

        try:
            with httpx.stream("GET", url, headers=headers, timeout=None) as response:
                if response.status_code == 404:
                    print("Error: item not found", file=sys.stderr)
                    sys.exit(1)
                if response.status_code >= 400:
                    print(f"Error: {response.status_code}", file=sys.stderr)
                    sys.exit(1)

                event_type = None
                for line in response.iter_lines():
                    if line.startswith("event: "):
                        event_type = line[7:]
                    elif line.startswith("data: ") and event_type:
                        import json
                        data = json.loads(line[6:])
                        yield (event_type, data)
                        event_type = None
                    elif line.startswith(":"):
                        # Comment/keepalive, ignore
                        pass
        except httpx.ConnectError:
            print(
                f"Error: could not connect to server at {self.base_url}",
                file=sys.stderr,
            )
            sys.exit(1)

    def _request(self, method: str, path: str, **kwargs) -> Any:
        """Make an HTTP request, handling errors."""
        try:
            response = self._client.request(method, path, **kwargs)
        except httpx.ConnectError:
            print(
                f"Error: could not connect to server at {self.base_url}",
                file=sys.stderr,
            )
            print("Is the Cham server running?", file=sys.stderr)
            sys.exit(1)
        except httpx.TimeoutException:
            print("Error: request timed out", file=sys.stderr)
            sys.exit(1)

        if response.status_code >= 400:
            try:
                body = response.json()
                msg = body.get("error", body.get("message", response.text))
            except Exception:
                msg = response.text
            print(
                f"Error: {response.status_code} — {msg}",
                file=sys.stderr,
            )
            sys.exit(1)

        if response.status_code == 204:
            return {}

        return response.json()
