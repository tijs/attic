/**
 * macOS notifications via osascript.
 * Falls back silently if osascript is unavailable.
 */

export async function notify(
  title: string,
  message: string,
  sound: string = "default",
): Promise<void> {
  try {
    const cmd = new Deno.Command("osascript", {
      args: [
        "-e",
        `display notification "${escapeAppleScript(message)}" with title "${escapeAppleScript(title)}" sound name "${escapeAppleScript(sound)}"`,
      ],
      stdout: "null",
      stderr: "null",
    });
    const { success } = await cmd.output();
    if (!success) {
      // Silently ignore — notifications are best-effort
    }
  } catch {
    // osascript not available or other error — skip silently
  }
}

function escapeAppleScript(s: string): string {
  return s
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\n/g, " ")
    .replace(/\r/g, "");
}
