import { addDays, subDays, format, parseISO } from 'date-fns';

export type CrewMember = 'crew_a' | 'crew_b';
export type RotationType = 'onboard' | 'off' | 'travel' | 'handover';

export interface CreateRotationInput {
	user_id: string;
	start_date: string;   // YYYY-MM-DD
	end_date: string;     // YYYY-MM-DD
	rotation_type: RotationType;
	crew_member: CrewMember;
	is_projected: boolean;
}

export interface LocalRotation {
	id: string;
	user_id: string;
	start_date: string;
	end_date: string;
	rotation_type: RotationType;
	crew_member: CrewMember;
	is_projected: boolean;
	locked?: boolean;
}

/**
 * Configuration for generating projected rotations.
 */
export interface ProjectionConfig {
	userId: string;
	startDate: string;            // YYYY-MM-DD
	startState: 'onboard' | 'off';
	daysOn: number;
	daysOff: number;
	cycles: number;               // Full on+off cycles
	crewMember: CrewMember;
}

/**
 * Generate projected rotation entries based on a cycle configuration.
 *
 * Pure function: no side effects, no Dexie writes.
 * Output feeds directly into createProjectionsBatch().
 *
 * Date arithmetic:
 * - Day 1 = start date, so a 28-day period starting Jan 1 ends Jan 28 (start + 27 days)
 * - Next period starts the day after: Jan 29
 * - Uses date-fns format() for YYYY-MM-DD strings (NOT toISOString to avoid UTC off-by-one)
 *
 * @param config - Projection generation parameters
 * @returns Array of CreateRotationInput entries with is_projected: true
 */
export function generateProjections(config: ProjectionConfig): CreateRotationInput[] {
	if (config.cycles === 0) {
		return [];
	}

	const results: CreateRotationInput[] = [];
	let cursor = parseISO(config.startDate);
	let currentType: 'onboard' | 'off' = config.startState;

	// Each cycle = on period + off period = 2 iterations
	const totalPeriods = config.cycles * 2;

	for (let i = 0; i < totalPeriods; i++) {
		const days = currentType === 'onboard' ? config.daysOn : config.daysOff;
		const endDate = addDays(cursor, days - 1);

		results.push({
			user_id: config.userId,
			start_date: format(cursor, 'yyyy-MM-dd'),
			end_date: format(endDate, 'yyyy-MM-dd'),
			rotation_type: currentType,
			crew_member: config.crewMember,
			is_projected: true
		});

		// Advance cursor to next period start (day after end)
		cursor = addDays(endDate, 1);

		// Alternate between onboard and off
		currentType = currentType === 'onboard' ? 'off' : 'onboard';
	}

	return results;
}

/**
 * Trim a set of to-be-inserted projections against existing confirmed rotations.
 *
 * For each projection, finds confirmed rotations of the SAME crew_member AND
 * rotation_type that overlap it, then subtracts those date ranges via interval
 * algebra, producing 0..N trimmed fragments.
 *
 * Cross-type and cross-crew overlaps are left unchanged — different-type coexistence
 * (e.g., onboard + travel on the same day) is intentional and renders as diagonal split.
 *
 * Date strings are YYYY-MM-DD (inclusive on both ends). Lexicographic comparison is safe.
 *
 * @param projections - Incoming projection inputs to trim
 * @param confirmed - Existing confirmed rotations to trim against
 * @returns Trimmed CreateRotationInput[] — may be longer than input (splits) or shorter (eliminations)
 */
export function trimProjectionsAgainstConfirmed(
	projections: CreateRotationInput[],
	confirmed: Pick<LocalRotation, 'start_date' | 'end_date' | 'rotation_type' | 'crew_member'>[]
): CreateRotationInput[] {
	const results: CreateRotationInput[] = [];

	for (const proj of projections) {
		// Only same crew_member + same rotation_type blockers matter
		const blockers = confirmed
			.filter(
				(c) => c.crew_member === proj.crew_member && c.rotation_type === proj.rotation_type
			)
			.sort((a, b) => a.start_date.localeCompare(b.start_date));

		// Start with full projection as a single fragment
		let fragments: { start: string; end: string }[] = [
			{ start: proj.start_date, end: proj.end_date }
		];

		// Incrementally subtract each blocker from the current fragment list
		for (const blocker of blockers) {
			const next: { start: string; end: string }[] = [];

			for (const frag of fragments) {
				// No overlap: blocker is entirely before or after fragment
				if (blocker.end_date < frag.start || blocker.start_date > frag.end) {
					next.push(frag);
					continue;
				}
				// Full cover: blocker eliminates the entire fragment
				if (blocker.start_date <= frag.start && blocker.end_date >= frag.end) {
					continue; // drop fragment
				}
				// Overlap at start: trim start_date
				if (blocker.start_date <= frag.start && blocker.end_date < frag.end) {
					const newStart = format(addDays(parseISO(blocker.end_date), 1), 'yyyy-MM-dd');
					if (newStart <= frag.end) next.push({ start: newStart, end: frag.end });
					continue;
				}
				// Overlap at end: trim end_date
				if (blocker.start_date > frag.start && blocker.end_date >= frag.end) {
					const newEnd = format(subDays(parseISO(blocker.start_date), 1), 'yyyy-MM-dd');
					if (frag.start <= newEnd) next.push({ start: frag.start, end: newEnd });
					continue;
				}
				// Blocker is in the middle: split into two fragments
				const leftEnd = format(subDays(parseISO(blocker.start_date), 1), 'yyyy-MM-dd');
				const rightStart = format(addDays(parseISO(blocker.end_date), 1), 'yyyy-MM-dd');
				if (frag.start <= leftEnd) next.push({ start: frag.start, end: leftEnd });
				if (rightStart <= frag.end) next.push({ start: rightStart, end: frag.end });
			}

			fragments = next;
		}

		// Map surviving fragments back to CreateRotationInput preserving original metadata
		for (const frag of fragments) {
			results.push({ ...proj, start_date: frag.start, end_date: frag.end });
		}
	}

	return results;
}
