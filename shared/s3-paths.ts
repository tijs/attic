const UUID_PATTERN = /^[A-Za-z0-9._-]+$/;
const EXT_PATTERN = /^[a-z0-9]+$/;

function assertSafeUuid(uuid: string): void {
  if (!UUID_PATTERN.test(uuid)) {
    throw new Error(`Unsafe UUID for S3 key: ${uuid}`);
  }
}

function assertSafeExtension(ext: string): void {
  if (!EXT_PATTERN.test(ext)) {
    throw new Error(`Unsafe extension for S3 key: ${ext}`);
  }
}

/** Generate S3 key for an original photo/video file. */
export function originalKey(
  uuid: string,
  dateCreated: Date | null,
  extension: string,
): string {
  assertSafeUuid(uuid);
  const year = dateCreated?.getUTCFullYear() ?? "unknown";
  const month = dateCreated
    ? String(dateCreated.getUTCMonth() + 1).padStart(2, "0")
    : "00";
  const ext = extension.toLowerCase().replace(/^\./, "");
  assertSafeExtension(ext);
  return `originals/${year}/${month}/${uuid}.${ext}`;
}

/** Generate S3 key for an asset's metadata JSON. */
export function metadataKey(uuid: string): string {
  assertSafeUuid(uuid);
  return `metadata/assets/${uuid}.json`;
}

/** UTI-to-extension lookup table. */
const utiMap: Record<string, string> = {
  "public.jpeg": "jpg",
  "public.heic": "heic",
  "public.png": "png",
  "public.tiff": "tiff",
  "com.compuserve.gif": "gif",
  "public.mpeg-4": "mp4",
  "com.apple.quicktime-movie": "mov",
  "com.apple.m4v-video": "m4v",
  "public.avi": "avi",
  "com.olympus.raw-image": "orf",
};

/** Extract file extension from a UTI or filename. */
export function extensionFromUtiOrFilename(
  uti: string | null,
  filename: string,
): string {
  if (uti && utiMap[uti]) return utiMap[uti];

  const dot = filename.lastIndexOf(".");
  if (dot >= 0) return filename.slice(dot + 1).toLowerCase();

  return "bin";
}
