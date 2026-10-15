import {
  LocalStorage,
  environment,
  showToast,
  Toast,
} from "@raycast/api";
import { execFile, spawn } from "child_process";
import { existsSync, readFileSync, statSync, rmSync, writeFileSync, mkdirSync } from "fs";
import { join } from "path";

interface State {
  pid: number;
  file: string;
}

const FFMPEG = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].find(existsSync) ?? "ffmpeg";
const STATE_FILE = join(environment.supportPath, "state.json");
const helperSrc = (name: string) => join(environment.assetsPath, `${name}.swift`);
const helperBin = (name: string) => join(environment.supportPath, name);
const STOP_URL = "raycast://extensions/wyatt/screen-recorder/record?launchType=background";
const AREA_KEY = "last-area";

const run = (cmd: string, args: string[]) =>
  new Promise<string>((resolve, reject) =>
    execFile(cmd, args, { maxBuffer: 1 << 24 }, (err, stdout, stderr) =>
      err ? reject(new Error(stderr || err.message)) : resolve(stdout),
    ),
  );

const isAlive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

const readState = (): State | undefined => {
  try {
    const s: State = JSON.parse(readFileSync(STATE_FILE, "utf8"));
    return isAlive(s.pid) ? s : undefined;
  } catch {
    return undefined;
  }
};

async function ensureHelper() {
  mkdirSync(environment.supportPath, { recursive: true });
  for (const name of ["select-area", "recording-indicator", "recording-editor"]) {
    const [src, bin] = [helperSrc(name), helperBin(name)];
    if (!existsSync(bin) || statSync(src).mtimeMs > statSync(bin).mtimeMs) await run("/usr/bin/swiftc", ["-O", src, "-o", bin]);
  }
}

async function startRecording() {
  const lock = join(environment.supportPath, "selecting.pid");
  try {
    if (isAlive(Number(readFileSync(lock, "utf8")))) return;
  } catch {
    /* no lock */
  }
  await ensureHelper();
  const last = await LocalStorage.getItem<string>(AREA_KEY);
  let out: string;
  try {
    out = await new Promise<string>((resolve, reject) => {
      const p = execFile(helperBin("select-area"), last ? last.split(",") : [], (err, stdout) =>
        err ? reject(err) : resolve(stdout),
      );
      writeFileSync(lock, String(p.pid));
    });
  } catch {
    return; // cancelled with Esc
  } finally {
    rmSync(lock, { force: true });
  }
  const parts = out.trim().split(",");
  const [x, y, w, h, scale, screen] = parts.slice(0, 6).map(Number);
  await LocalStorage.setItem(AREA_KEY, [x, y, w, h, screen].join(","));

  const even = (n: number) => Math.max(2, Math.floor(n / 2) * 2);
  const crop = `crop=${even(w * scale)}:${even(h * scale)}:${x * scale}:${y * scale}`;
  const file = join(environment.supportPath, `recording-${Date.now()}.mp4`);

  const child = spawn(
    FFMPEG,
    [
      "-y", "-f", "avfoundation", "-capture_cursor", "1", "-framerate", "30",
      "-i", `Capture screen ${screen}`,
      "-vf", `${crop},format=yuv420p`,
      "-c:v", "libx264", "-preset", "ultrafast", "-crf", "18",
      "-movflags", "frag_keyframe+empty_moov+default_base_moof",
      file,
    ],
    { detached: true, stdio: "ignore" },
  );
  child.unref();
  spawn(helperBin("recording-indicator"), [String(child.pid), STOP_URL], { detached: true, stdio: "ignore" }).unref();
  writeFileSync(STATE_FILE, JSON.stringify({ pid: child.pid!, file } satisfies State));
}

async function stopRecording(state: State) {
  process.kill(state.pid, "SIGINT");
  for (let i = 0; i < 50 && isAlive(state.pid); i++) await new Promise((r) => setTimeout(r, 100));
  rmSync(STATE_FILE, { force: true });
}

export default async function Command() {
  try {
    const state = readState();
    if (!state) return await startRecording();
    await stopRecording(state);
    spawn(helperBin("recording-editor"), [state.file, FFMPEG], { detached: true, stdio: "ignore" }).unref();
  } catch (e) {
    await showToast({ style: Toast.Style.Failure, title: "Failed", message: String((e as Error).message ?? e) });
  }
}
