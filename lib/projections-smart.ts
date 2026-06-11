import { addDays, differenceInCalendarDays, format, parseISO } from 'date-fns';
import type { CreateRotationInput, CrewMember } from './projections.js';

/**
 * Smart projector (Phase 6, PROJ-RES-05).
 *
 * Greedy boundary optimisation on a nominal-anchored grid — see
 * management repo .planning/phases/06-smart-projections/06-ALGORITHM.md.
 * Pure functions: no I/O, no clock reads (today is an explicit input),
 * deterministic output for identical inputs.
 *
 * All dates are YYYY-MM-DD strings; comparisons are lexicographic
 * (safe for ISO dates — same convention as projections.ts).
 */

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface ImportantDate {
	date: string;          // YYYY-MM-DD; anchor occurrence when recur_yearly
	label: string;
	priority: number;      // 1–5, 5 highest
	recur_yearly: boolean;
}

/** Vessel blackout window sourced from org_events (null end → single day). */
export interface Blackout {
	start_date: string;
	end_date: string | null;
	title?: string;
}

export interface DateRange {
	start_date: string;
	end_date: string;
}

export interface SmartProjectionConfig {
	userId: string;
	crewMember: CrewMember;
	startDate: string;            // YYYY-MM-DD — period 0 start (unshiftable)
	startState: 'onboard' | 'off';
	daysOn: number;
	daysOff: number;
	cycles: number;               // on+off pairs
	flexDays?: number;            // boundary shift bound, default 7 (edge case 5)
	minOffDays?: number;          // statutory rest, default 7 (edge case 2)
	maxOnboardDays?: number;      // default daysOn + flexDays (edge case 2)
}

export interface SmartContext {
	lockedRotations: DateRange[];  // member's own locked rotations (edge case 8)
	partnerOnboard: DateRange[];   // partner onboard ranges — P-05 (edge case 1)
	importantDates: ImportantDate[];
	blackouts: Blackout[];         // edge case 3
	today?: string;                // default config.startDate (edge case 9)
}

export interface BoundaryDecision {
	periodIndex: number;
	nominalDate: string;
	chosenDate: string;
	shiftDays: number;
	/**
	 * Dominant cause: 'important-date' when the shift satisfies a date the
	 * nominal position would not; otherwise the constraint that forced the
	 * move ('blackout' / 'locked' / 'forced'); 'nominal' when unshifted.
	 */
	reason: 'important-date' | 'blackout' | 'locked' | 'forced' | 'nominal';
	detail?: string;
}

export interface UnresolvedConflict {
	date: string;
	label: string;
	priority: number;
	reason: 'competing-priority' | 'partner-conflict' | 'out-of-flex';
}

export interface ScoreBreakdown {
	importantDatesSatisfied: number;
	importantDatesTotal: number;
	importantDateScore: number;  // Σ priority × 10 over satisfied
	driftPenalty: number;        // Σ |shift| over boundaries
	total: number;               // importantDateScore − driftPenalty
}

export interface SmartProjectionResult {
	rotations: CreateRotationInput[];
	score: ScoreBreakdown;
	decisions: BoundaryDecision[];
	unresolved: UnresolvedConflict[];
}

// ---------------------------------------------------------------------------
// Date helpers (internal)
// ---------------------------------------------------------------------------

function shiftDate(date: string, days: number): string {
	return format(addDays(parseISO(date), days), 'yyyy-MM-dd');
}

function daysBetween(later: string, earlier: string): number {
	return differenceInCalendarDays(parseISO(later), parseISO(earlier));
}

function isLeapYear(year: number): boolean {
	return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
}

// ---------------------------------------------------------------------------
// expandImportantDates — edge case 9
// ---------------------------------------------------------------------------

/**
 * Expand important dates into concrete future occurrences within
 * [max(windowStart, today), windowEnd].
 *
 * - Occurrences before `today` are dropped — past dates never influence
 *   boundary choice nor appear in unresolved conflicts (edge case 9).
 * - recur_yearly anchors emit one occurrence per in-window year; Feb-29
 *   anchors map to Feb-28 in non-leap years (deterministic).
 * - Output order is deterministic: date asc, priority desc, label asc.
 */
export function expandImportantDates(
	dates: ImportantDate[],
	windowStart: string,
	windowEnd: string,
	today: string
): ImportantDate[] {
	const effectiveStart = windowStart > today ? windowStart : today;
	const results: ImportantDate[] = [];

	for (const d of dates) {
		if (!d.recur_yearly) {
			if (d.date >= effectiveStart && d.date <= windowEnd) {
				results.push({ ...d });
			}
			continue;
		}

		// Yearly recurrence: project the anchor's month-day into each window year
		const monthDay = d.date.slice(5); // MM-DD
		const fromYear = Number(effectiveStart.slice(0, 4));
		const toYear = Number(windowEnd.slice(0, 4));
		for (let year = fromYear; year <= toYear; year++) {
			const occurrenceDay =
				monthDay === '02-29' && !isLeapYear(year) ? '02-28' : monthDay;
			const occurrence = `${year}-${occurrenceDay}`;
			if (occurrence >= effectiveStart && occurrence <= windowEnd) {
				results.push({ ...d, date: occurrence });
			}
		}
	}

	results.sort(
		(a, b) =>
			a.date.localeCompare(b.date) ||
			b.priority - a.priority ||
			a.label.localeCompare(b.label)
	);
	return results;
}

// ---------------------------------------------------------------------------
// scoreImportantDates — objective function (06-PROJ-SPEC §3)
// ---------------------------------------------------------------------------

/**
 * Score a rotation plan against expanded important dates: a date is
 * satisfied when it falls inside an emitted OFF period (inclusive ends).
 * Exported standalone so a linear plan can be scored with the identical
 * metric (smart-beats-linear comparison, success criterion 5).
 */
export function scoreImportantDates(
	rotations: Pick<CreateRotationInput, 'start_date' | 'end_date' | 'rotation_type'>[],
	expanded: ImportantDate[]
): { satisfied: number; total: number; score: number } {
	const offPeriods = rotations.filter((r) => r.rotation_type === 'off');
	let satisfied = 0;
	let score = 0;
	for (const d of expanded) {
		const isOff = offPeriods.some(
			(p) => d.date >= p.start_date && d.date <= p.end_date
		);
		if (isOff) {
			satisfied += 1;
			score += d.priority * 10;
		}
	}
	return { satisfied, total: expanded.length, score };
}

// ---------------------------------------------------------------------------
// generateSmartProjections — greedy nominal-anchored boundary optimisation
// (06-ALGORITHM.md §3–§5)
// ---------------------------------------------------------------------------

interface NormalizedBlackout {
	start_date: string;
	end_date: string;
	title?: string;
}

type RejectionCause = 'length' | 'blackout' | 'locked' | 'partner';

function inAnyRange<T extends { start_date: string; end_date: string }>(
	day: string,
	ranges: T[]
): T | undefined {
	return ranges.find((r) => day >= r.start_date && day <= r.end_date);
}

function rangesOverlap(aStart: string, aEnd: string, bStart: string, bEnd: string): boolean {
	return aStart <= bEnd && aEnd >= bStart;
}

export function generateSmartProjections(
	config: SmartProjectionConfig,
	context: SmartContext
): SmartProjectionResult {
	const flex = config.flexDays ?? 7;
	const minOff = config.minOffDays ?? 7;
	const maxOn = config.maxOnboardDays ?? config.daysOn + flex;
	const today = context.today ?? config.startDate;
	const totalPeriods = config.cycles * 2;

	if (totalPeriods === 0) {
		return {
			rotations: [],
			score: {
				importantDatesSatisfied: 0,
				importantDatesTotal: 0,
				importantDateScore: 0,
				driftPenalty: 0,
				total: 0,
			},
			decisions: [],
			unresolved: [],
		};
	}

	const typeOf = (i: number): 'onboard' | 'off' =>
		i % 2 === 0 ? config.startState : config.startState === 'onboard' ? 'off' : 'onboard';
	const lenOf = (i: number): number => (typeOf(i) === 'onboard' ? config.daysOn : config.daysOff);

	// Nominal grid — fixed; boundaries anchor here, never to chosen neighbours
	// (structurally prevents compounding drift, edge case 6).
	const nominal: string[] = [config.startDate];
	for (let i = 1; i <= totalPeriods; i++) {
		nominal.push(shiftDate(nominal[i - 1], lenOf(i - 1)));
	}

	const horizonEnd = shiftDate(nominal[totalPeriods], flex);
	const expanded = expandImportantDates(
		context.importantDates,
		config.startDate,
		horizonEnd,
		today
	);
	const blackouts: NormalizedBlackout[] = context.blackouts.map((b) => ({
		start_date: b.start_date,
		end_date: b.end_date ?? b.start_date,
		title: b.title,
	}));
	const keyOf = (d: ImportantDate) => `${d.date}|${d.label}`;

	// Per-date tracking for the unresolved classifier (06-ALGORITHM §5):
	// a satisfying candidate rejected by a hard constraint, and whether a
	// VALID satisfying candidate existed anywhere (lost on score).
	const rejectedSatisfying = new Map<string, RejectionCause>();
	const validSatisfying = new Set<string>();

	// Candidate enumeration order: |shift| ascending, negative first — the
	// first strict-max wins, making all tie-breaks deterministic.
	const candidateOrder: number[] = [0];
	for (let s = 1; s <= flex; s++) candidateOrder.push(-s, s);

	const chosen: string[] = [config.startDate];
	const shifts: number[] = [0];
	const decisions: BoundaryDecision[] = [];

	for (let i = 1; i < totalPeriods; i++) {
		const prevType = typeOf(i - 1);
		const curType = typeOf(i);
		const windowStart = chosen[i - 1];
		const windowEnd = shiftDate(nominal[i + 1], -1);
		const localDates = expanded.filter((d) => d.date >= windowStart && d.date <= windowEnd);

		interface Candidate {
			c: number;
			day: string;
			satisfied: Set<string>;
			score: number;
		}
		let best: Candidate | null = null;
		let zeroSatisfied = new Set<string>();
		let zeroRejection: RejectionCause | null = null;
		let zeroDetail: string | undefined;

		for (const c of candidateOrder) {
			const day = shiftDate(nominal[i], c);

			// Satisfaction set under this candidate (dates before the boundary
			// belong to period i−1, on/after to period i) — computed even for
			// invalid candidates, for decision reasons and conflict tracking.
			const satisfied = new Set<string>();
			for (const d of localDates) {
				const periodType = d.date < day ? prevType : curType;
				if (periodType === 'off') satisfied.add(keyOf(d));
			}

			// Hard-constraint filter
			let rejection: RejectionCause | null = null;
			let detail: string | undefined;
			const lenPrev = daysBetween(day, chosen[i - 1]);
			if (lenPrev < 1) {
				rejection = 'length';
			} else if (prevType === 'off' && lenPrev < minOff) {
				rejection = 'length';
			} else if (prevType === 'onboard' && lenPrev > maxOn) {
				rejection = 'length';
			}
			if (!rejection) {
				const b = inAnyRange(day, blackouts);
				if (b) {
					rejection = 'blackout';
					detail = b.title;
				}
			}
			if (!rejection && inAnyRange(day, context.lockedRotations)) {
				rejection = 'locked';
			}
			if (!rejection && curType === 'onboard') {
				// P-05 provisional span check; the post-pass re-checks final spans
				const provisionalEnd = shiftDate(day, lenOf(i) - 1);
				if (
					context.partnerOnboard.some((p) =>
						rangesOverlap(day, provisionalEnd, p.start_date, p.end_date)
					)
				) {
					rejection = 'partner';
				}
			}

			if (c === 0) {
				zeroSatisfied = satisfied;
				zeroRejection = rejection;
				zeroDetail = detail;
			}

			if (rejection) {
				for (const k of satisfied) {
					// Partner rejections take precedence in the classifier (edge case 10)
					if (rejection === 'partner' || !rejectedSatisfying.has(k)) {
						rejectedSatisfying.set(k, rejection);
					}
				}
				continue;
			}

			for (const k of satisfied) validSatisfying.add(k);

			let score = -Math.abs(c);
			for (const d of localDates) {
				if (satisfied.has(keyOf(d))) score += d.priority * 10;
			}
			if (!best || score > best.score) {
				best = { c, day, satisfied, score };
			}
		}

		if (!best) {
			// No valid candidate in the flex window — keep nominal, report;
			// the RPC backstop protects the eventual commit (06-ALGORITHM §3).
			chosen.push(nominal[i]);
			shifts.push(0);
			decisions.push({
				periodIndex: i,
				nominalDate: nominal[i],
				chosenDate: nominal[i],
				shiftDays: 0,
				reason: 'nominal',
				detail: 'no valid candidate within flex window',
			});
			continue;
		}

		chosen.push(best.day);
		shifts.push(best.c);

		let reason: BoundaryDecision['reason'];
		let detail: string | undefined;
		if (best.c === 0) {
			reason = 'nominal';
		} else {
			const newlySatisfied = localDates.filter(
				(d) => best!.satisfied.has(keyOf(d)) && !zeroSatisfied.has(keyOf(d))
			);
			if (newlySatisfied.length > 0) {
				reason = 'important-date';
				detail = newlySatisfied.map((d) => `${d.label} (P${d.priority})`).join(', ');
			} else if (zeroRejection === 'blackout') {
				reason = 'blackout';
				detail = zeroDetail;
			} else if (zeroRejection === 'locked') {
				reason = 'locked';
			} else if (zeroRejection) {
				reason = 'forced';
				detail = zeroRejection;
			} else {
				// Unreachable: a no-gain shift always scores below a valid nominal
				reason = 'nominal';
			}
		}
		decisions.push({
			periodIndex: i,
			nominalDate: nominal[i],
			chosenDate: best.day,
			shiftDays: best.c,
			reason,
			detail,
		});
	}

	chosen.push(nominal[totalPeriods]); // end sentinel — last period ends on grid

	// Emission
	const emitted: CreateRotationInput[] = [];
	for (let i = 0; i < totalPeriods; i++) {
		emitted.push({
			user_id: config.userId,
			start_date: chosen[i],
			end_date: shiftDate(chosen[i + 1], -1),
			rotation_type: typeOf(i),
			crew_member: config.crewMember,
			is_projected: true,
		});
	}

	// Post-pass P-05 (edge case 1): onboard periods still overlapping partner
	// onboard can never commit (RPC rejects) — drop them and surface the
	// conflict instead of emitting a doomed plan.
	const dropped: CreateRotationInput[] = [];
	const rotations = emitted.filter((r) => {
		if (r.rotation_type !== 'onboard') return true;
		const hit = context.partnerOnboard.some((p) =>
			rangesOverlap(r.start_date, r.end_date, p.start_date, p.end_date)
		);
		if (hit) dropped.push(r);
		return !hit;
	});

	const driftPenalty = shifts.reduce((sum, s) => sum + Math.abs(s), 0);
	const ids = scoreImportantDates(rotations, expanded);

	// Unresolved classification (06-ALGORITHM §5, edge cases 4 & 10)
	const satisfiedFinal = new Set(
		expanded
			.filter((d) =>
				rotations.some(
					(p) =>
						p.rotation_type === 'off' && d.date >= p.start_date && d.date <= p.end_date
				)
			)
			.map(keyOf)
	);
	const seen = new Set<string>();
	const unresolved: UnresolvedConflict[] = [];
	for (const d of expanded) {
		const k = keyOf(d);
		if (satisfiedFinal.has(k) || seen.has(k)) continue;
		seen.add(k);
		const inDroppedSpan = dropped.some(
			(p) => d.date >= p.start_date && d.date <= p.end_date
		);
		let reason: UnresolvedConflict['reason'];
		if (rejectedSatisfying.get(k) === 'partner' || inDroppedSpan) {
			reason = 'partner-conflict';
		} else if (validSatisfying.has(k)) {
			reason = 'competing-priority';
		} else {
			reason = 'out-of-flex';
		}
		unresolved.push({ date: d.date, label: d.label, priority: d.priority, reason });
	}

	return {
		rotations,
		score: {
			importantDatesSatisfied: ids.satisfied,
			importantDatesTotal: ids.total,
			importantDateScore: ids.score,
			driftPenalty,
			total: ids.score - driftPenalty,
		},
		decisions,
		unresolved,
	};
}
