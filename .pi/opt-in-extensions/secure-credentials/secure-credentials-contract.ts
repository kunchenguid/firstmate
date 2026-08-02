/** The status returned for one requested credential. */
export type SecureCredentialStatus = "applied" | "skipped" | "cancelled";

/** The safe result returned for one requested credential. */
export interface SecureCredentialResult {
	/** The allowlisted environment-style key name. */
	key: string;
	/** The operator-defined logical destination name. */
	destination: string;
	/** The outcome without a credential value. */
	status: SecureCredentialStatus;
}

/** The tool details that are safe to persist in a Pi session. */
export interface SecureCredentialsToolDetails {
	/** Results contain names and statuses only. */
	results: SecureCredentialResult[];
}

/** One operator-defined local file destination. */
export interface SecureCredentialsDestination {
	/** The logical destination name shown to the operator. */
	id: string;
	/** The resolved local file path controlled by the manifest. */
	path: string;
	/** The allowlisted key names accepted by this destination. */
	keys: string[];
}

/** The versioned operator-owned allowlist manifest. */
export interface SecureCredentialsManifest {
	/** The manifest schema version. */
	version: 1;
	/** The local destinations and their allowlisted keys. */
	destinations: SecureCredentialsDestination[];
}

/** The only tool arguments accepted from the model. */
export interface SecureCredentialsRequest {
	/** Allowlisted key names requested by the model. */
	keys: string[];
}

/** The outcome of a masked TUI value page. */
export type SecureCredentialInputOutcome =
	| { kind: "submitted"; value: string }
	| { kind: "cancelled" };

/** The outcome of a TUI overwrite page. */
export type SecureCredentialOverwriteOutcome =
	| { kind: "replace" }
	| { kind: "skip" }
	| { kind: "cancelled" };
