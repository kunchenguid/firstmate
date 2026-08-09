// OMP entrypoint for Firstmate's shared Pi-family watcher bridge. Loading THIS
// file is the authoritative OMP signal - only OMP discovers .omp/extensions/ -
// so the harness travels as an argument rather than an inheritable env marker.
import registerPiFamilyPrimaryWatch from "../../.pi/extensions/fm-primary-pi-watch.ts";

export default function (omp: any): void {
  registerPiFamilyPrimaryWatch(omp, "omp");
}
