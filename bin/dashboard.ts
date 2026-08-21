// dashboard.ts - launcher shim. The dashboard lives in dashboard/ at the repo
// root (app.ts + assets/); this file keeps the stable entry path that
// bin/ac-dashboard.sh execs and that older imports resolve.
export * from "../dashboard/app.ts";
import { dashboardMain } from "../dashboard/app.ts";

if (import.meta.main) dashboardMain();
