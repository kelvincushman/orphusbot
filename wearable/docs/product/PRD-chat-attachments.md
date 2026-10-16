<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Server spec — Chat image/video attachments (`/api/chat` multipart)

**For:** the Wearable **server-side** coding assistant. **Status:** Draft v1 · 2026-06-08.

## Problem
The Wearable app's chat composer is gaining **image/video attachment** support (pick + preview already built client-side). But `POST /api/chat?stream=1` currently accepts **JSON only** (`{message, chatId, businessId}`) — no way to send files. The server must accept attachments and make them available to the agent.

## Required change
Accept **multipart/form-data** on the chat POST (in addition to the existing JSON path — keep JSON working for text-only):
- Fields: `message` (text), `chatId`, `businessId` (optional), plus **`attachments[]`** (one or more files: images `image/*`, video `video/*`).
- Validate: content-type allowlist (jpeg/png/webp/heic, mp4/mov), per-file size cap (e.g. 25 MB image / 200 MB video — your call), max count (e.g. 4), reject others.
- Persist each attachment to the per-business artifact/store (reuse whatever the device/artifact pipeline uses) and pass references/paths into the agent turn (`wearable/agent.prompt`) so the CoS (and a vision-capable model) can see them. For images, make them available to the multimodal model; for video, at minimum store + reference (transcription/frames optional later).
- Stream the reply on the same chatId/SSE as today.

## Acceptance
- App sends a chat message with 1–4 images → server stores them, the agent can reference/See them, reply streams back.
- Text-only JSON POST still works unchanged.
- Oversized/disallowed files rejected with a clear error the app can show.

## App side (built, pending this)
The app builds a multipart request to `/api/chat?stream=1` with `message` + `attachments[]` (via `image_picker`/`file_picker`, reusing the `message_provider.dart` upload pattern). Until this server change ships, the app's attachment send fails gracefully with a "attachments need a server update" message; text chat is unaffected.
