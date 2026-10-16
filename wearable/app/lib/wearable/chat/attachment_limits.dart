// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.

/// Attachment limits shared by the Wearable chat picker and HTTP client.
/// These mirror the server's `/api/chat/uploads` contract.
const int kWearableMaxAttachments = 8;
const int kWearableMaxAttachmentBytes = 25 * 1024 * 1024;

String wearableAttachmentSizeLabel(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}

/// Returns a user-facing validation error, or null when the file is accepted.
String? wearableAttachmentSizeError({required String name, required int bytes}) {
  if (bytes <= kWearableMaxAttachmentBytes) return null;
  return '$name is ${wearableAttachmentSizeLabel(bytes)}. The maximum attachment size is 25 MB.';
}
