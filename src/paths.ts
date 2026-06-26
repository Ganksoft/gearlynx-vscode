import * as os from 'os';
import * as path from 'path';

// Expand a leading "~" (or "~/..." / "~\...") to the user's home directory.
// VSCode and Node do not perform shell tilde expansion, so paths entered with
// a "~" must be expanded before they reach any fs or child_process call.
// Returns the input unchanged when it is empty or does not start with "~".
export function expandTilde(p: string | undefined): string | undefined {
    if (!p) {
        return p;
    }
    if (p === '~') {
        return os.homedir();
    }
    if (p.startsWith('~/') || p.startsWith('~\\')) {
        return path.join(os.homedir(), p.slice(2));
    }
    return p;
}
