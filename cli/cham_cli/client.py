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
        """Check server health via GET /api/health."""
        return self._request("GET", "/api/health")

    def submit_item(self, url: str, tags: Optional[list[str]] = None) -> dict:
        """Submit a URL for archiving via POST /api/items."""
        payload: dict[str, Any] = {"url": url}
        if tags:
            payload["tags"] = tags
        return self._request("POST", "/api/items", json=payload)

    def list_items(
        self,
        status: Optional[str] = None,
        content_type: Optional[str] = None,
        tag: Optional[str] = None,
    ) -> list[dict]:
        """List items via GET /api/items."""
        params: dict[str, str] = {}
        if status:
            params["status"] = status
        if content_type:
            params["type"] = content_type
        if tag:
            params["tag"] = tag
        result = self._request("GET", "/api/items", params=params)
        # The API may wrap items in a "data" key
        if isinstance(result, dict) and "data" in result:
            return result["data"]
        if isinstance(result, list):
            return result
        return []

    def get_item(self, id_or_slug: str) -> dict:
        """Get a single item via GET /api/items/:id_or_slug."""
        return self._request("GET", f"/api/items/{id_or_slug}")

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
