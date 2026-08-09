// OMP entrypoint for Firstmate's shared Pi-family turn-end guard. Loading THIS
// file is the authoritative OMP signal - only OMP discovers .omp/extensions/ -
// so the harness travels as an argument rather than an inheritable env marker.
import registerPiFamilyPrimaryTurnendGuard from "../../.pi/extensions/fm-primary-turnend-guard.ts";

export default function (omp: any): void {
  registerPiFamilyPrimaryTurnendGuard(omp, "omp");
}
