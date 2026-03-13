const FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

export interface Spinner {
  update(message: string): void;
  stop(): void;
}

/** Start a spinner with an animated indicator and message. */
export function startSpinner(message: string): Spinner {
  let frame = 0;
  let current = message;
  const isTTY = Deno.stdout.isTerminal();

  if (!isTTY) {
    // Non-interactive: just print the message once
    console.log(`  ${message}`);
    return {
      update(msg: string) { console.log(`  ${msg}`); },
      stop() {},
    };
  }

  const encoder = new TextEncoder();
  const write = (text: string) => Deno.stdout.writeSync(encoder.encode(text));

  const render = () => {
    write(`\r  ${FRAMES[frame]} ${current}`);
    frame = (frame + 1) % FRAMES.length;
  };

  render();
  const interval = setInterval(render, 80);

  return {
    update(msg: string) {
      // Clear current line and show new message
      write(`\r\x1b[2K`);
      current = msg;
      render();
    },
    stop() {
      clearInterval(interval);
      write(`\r\x1b[2K`);
    },
  };
}
