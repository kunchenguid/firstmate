// OMP entrypoint for Firstmate's shared Pi-family turn-end guard.
import registerPiFamilyPrimaryTurnendGuard from "../../.pi/extensions/fm-primary-turnend-guard.ts";

export default function (omp: any): void {
  registerPiFamilyPrimaryTurnendGuard(omp);
}
