const ACCOUNT = "attic";

export interface KeychainCredentials {
  accessKeyId: string;
  secretAccessKey: string;
}

/** Read S3 credentials from macOS Keychain. */
export async function loadKeychainCredentials(
  accessKeyService = "attic-s3-access-key",
  secretKeyService = "attic-s3-secret-key",
): Promise<KeychainCredentials> {
  const accessKeyId = await keychainGet(accessKeyService);
  const secretAccessKey = await keychainGet(secretKeyService);
  return { accessKeyId, secretAccessKey };
}

/** Store a credential in macOS Keychain. Uses -U to update if it already exists. */
export async function storeKeychainCredential(
  service: string,
  value: string,
): Promise<void> {
  const cmd = new Deno.Command("security", {
    args: [
      "add-generic-password",
      "-U",
      "-s",
      service,
      "-a",
      ACCOUNT,
      "-w",
      value,
    ],
    stderr: "piped",
  });
  const { code, stderr } = await cmd.output();
  if (code !== 0) {
    const err = new TextDecoder().decode(stderr);
    throw new Error(
      `Failed to store credential in Keychain for service "${service}": ${err.trim()}`,
    );
  }
}

async function keychainGet(service: string): Promise<string> {
  const cmd = new Deno.Command("security", {
    args: [
      "find-generic-password",
      "-s",
      service,
      "-w",
    ],
    stdout: "piped",
    stderr: "piped",
  });
  const { code, stdout, stderr } = await cmd.output();
  if (code !== 0) {
    const err = new TextDecoder().decode(stderr);
    throw new Error(
      `Failed to read keychain item "${service}": ${err.trim()}. ` +
        `Store it with: security add-generic-password -s ${service} -a ${ACCOUNT} -w "<value>"`,
    );
  }
  return new TextDecoder().decode(stdout).trim();
}
