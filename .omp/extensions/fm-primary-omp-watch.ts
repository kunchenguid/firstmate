// OMP entrypoint for Firstmate's shared Pi-family watcher bridge.
import registerPiFamilyPrimaryWatch from "../../.pi/extensions/fm-primary-pi-watch.ts";

export default function (omp: any): void {
  registerPiFamilyPrimaryWatch(omp);
}
