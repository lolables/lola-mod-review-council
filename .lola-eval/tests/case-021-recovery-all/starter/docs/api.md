# API Reference

## GET /health

Returns the current health status of the service.

**Response:**
```json
{
  "service": "userapi",
  "version": "0.1.0",
  "healthy": true
}
```

**Status codes:**
- 200 — service is healthy
