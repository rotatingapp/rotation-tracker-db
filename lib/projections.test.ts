import { describe, it, expect } from 'vitest';
import { generateProjections, trimProjectionsAgainstConfirmed, type ProjectionConfig } from './projections';
import type { CreateRotationInput, LocalRotation, RotationType, CrewMember } from './projections';

/**
 * Helper to create a minimal valid ProjectionConfig.
 */
function makeConfig(overrides: Partial<ProjectionConfig> = {}): ProjectionConfig {
	return {
		userId: 'test-user',
		startDate: '2026-01-01',
		startState: 'onboard',
		daysOn: 28,
		daysOff: 28,
		cycles: 1,
		crewMember: 'crew_a',
		...overrides
	};
}

describe('generateProjections', () => {
	it('1 cycle of 28/28 starting as onboard produces 2 rotations: onboard Jan 1-28, off Jan 29 - Feb 25', () => {
		const result = generateProjections(makeConfig({
			startDate: '2026-01-01',
			startState: 'onboard',
			daysOn: 28,
			daysOff: 28,
			cycles: 1
		}));

		expect(result).toHaveLength(2);

		// Entry 1: onboard Jan 1 - Jan 28
		expect(result[0].start_date).toBe('2026-01-01');
		expect(result[0].end_date).toBe('2026-01-28');
		expect(result[0].rotation_type).toBe('onboard');

		// Entry 2: off Jan 29 - Feb 25
		expect(result[1].start_date).toBe('2026-01-29');
		expect(result[1].end_date).toBe('2026-02-25');
		expect(result[1].rotation_type).toBe('off');
	});

	it('1 cycle of 28/28 starting as off produces 2 rotations: off Jan 1-28, onboard Jan 29 - Feb 25', () => {
		const result = generateProjections(makeConfig({
			startDate: '2026-01-01',
			startState: 'off',
			daysOn: 28,
			daysOff: 28,
			cycles: 1
		}));

		expect(result).toHaveLength(2);

		// Entry 1: off Jan 1 - Jan 28
		expect(result[0].start_date).toBe('2026-01-01');
		expect(result[0].end_date).toBe('2026-01-28');
		expect(result[0].rotation_type).toBe('off');

		// Entry 2: onboard Jan 29 - Feb 25
		expect(result[1].start_date).toBe('2026-01-29');
		expect(result[1].end_date).toBe('2026-02-25');
		expect(result[1].rotation_type).toBe('onboard');
	});

	it('3 cycles of 14/14 produces 6 rotations with correct alternating types and contiguous dates', () => {
		const result = generateProjections(makeConfig({
			startDate: '2026-01-01',
			startState: 'onboard',
			daysOn: 14,
			daysOff: 14,
			cycles: 3
		}));

		expect(result).toHaveLength(6);

		// Verify alternating types
		expect(result[0].rotation_type).toBe('onboard');
		expect(result[1].rotation_type).toBe('off');
		expect(result[2].rotation_type).toBe('onboard');
		expect(result[3].rotation_type).toBe('off');
		expect(result[4].rotation_type).toBe('onboard');
		expect(result[5].rotation_type).toBe('off');

		// Verify contiguous dates: period N end + 1 day = period N+1 start
		for (let i = 0; i < result.length - 1; i++) {
			const endDate = new Date(result[i].end_date);
			const nextStart = new Date(result[i + 1].start_date);
			const diffMs = nextStart.getTime() - endDate.getTime();
			const diffDays = diffMs / (1000 * 60 * 60 * 24);
			expect(diffDays).toBe(1);
		}

		// Verify first and last dates
		expect(result[0].start_date).toBe('2026-01-01');
		expect(result[0].end_date).toBe('2026-01-14');
		expect(result[5].start_date).toBe('2026-03-12');
		expect(result[5].end_date).toBe('2026-03-25');
	});

	it('unequal cycles (21 on / 21 off) produces correct date ranges', () => {
		const result = generateProjections(makeConfig({
			startDate: '2026-01-01',
			startState: 'onboard',
			daysOn: 21,
			daysOff: 21,
			cycles: 1
		}));

		expect(result).toHaveLength(2);

		// 21-day onboard: Jan 1 to Jan 21
		expect(result[0].start_date).toBe('2026-01-01');
		expect(result[0].end_date).toBe('2026-01-21');
		expect(result[0].rotation_type).toBe('onboard');

		// 21-day off: Jan 22 to Feb 11
		expect(result[1].start_date).toBe('2026-01-22');
		expect(result[1].end_date).toBe('2026-02-11');
		expect(result[1].rotation_type).toBe('off');
	});

	it('all generated entries have is_projected: true', () => {
		const result = generateProjections(makeConfig({ cycles: 3 }));
		expect(result.length).toBeGreaterThan(0);
		for (const entry of result) {
			expect(entry.is_projected).toBe(true);
		}
	});

	it('all generated entries have correct crew_member from config', () => {
		const resultA = generateProjections(makeConfig({ crewMember: 'crew_a', cycles: 2 }));
		for (const entry of resultA) {
			expect(entry.crew_member).toBe('crew_a');
		}

		const resultB = generateProjections(makeConfig({ crewMember: 'crew_b', cycles: 2 }));
		for (const entry of resultB) {
			expect(entry.crew_member).toBe('crew_b');
		}
	});

	it('0 cycles produces empty array', () => {
		const result = generateProjections(makeConfig({ cycles: 0 }));
		expect(result).toEqual([]);
	});

	it('boundary - cycle starting on Feb 28 (non-leap) correctly wraps to March', () => {
		// 2026 is NOT a leap year, so Feb has 28 days
		const result = generateProjections(makeConfig({
			startDate: '2026-02-28',
			startState: 'onboard',
			daysOn: 7,
			daysOff: 7,
			cycles: 1
		}));

		expect(result).toHaveLength(2);

		// 7-day onboard: Feb 28 to Mar 6
		expect(result[0].start_date).toBe('2026-02-28');
		expect(result[0].end_date).toBe('2026-03-06');
		expect(result[0].rotation_type).toBe('onboard');

		// 7-day off: Mar 7 to Mar 13
		expect(result[1].start_date).toBe('2026-03-07');
		expect(result[1].end_date).toBe('2026-03-13');
		expect(result[1].rotation_type).toBe('off');
	});

	it('all entries have correct user_id from config', () => {
		const result = generateProjections(makeConfig({ userId: 'custom-user-123', cycles: 2 }));
		for (const entry of result) {
			expect(entry.user_id).toBe('custom-user-123');
		}
	});

	it('return type matches CreateRotationInput[]', () => {
		const result: CreateRotationInput[] = generateProjections(makeConfig({ cycles: 1 }));
		expect(result).toHaveLength(2);
		// Verify shape has all required CreateRotationInput fields
		for (const entry of result) {
			expect(entry).toHaveProperty('user_id');
			expect(entry).toHaveProperty('start_date');
			expect(entry).toHaveProperty('end_date');
			expect(entry).toHaveProperty('rotation_type');
			expect(entry).toHaveProperty('crew_member');
			expect(entry).toHaveProperty('is_projected');
		}
	});
});

describe('trimProjectionsAgainstConfirmed', () => {
	// Helper to build a confirmed rotation blocker (Pick<LocalRotation, ...>)
	function makeConfirmed(
		start_date: string,
		end_date: string,
		rotation_type: RotationType = 'onboard',
		crew_member: CrewMember = 'crew_a'
	): Pick<LocalRotation, 'start_date' | 'end_date' | 'rotation_type' | 'crew_member'> {
		return { start_date, end_date, rotation_type, crew_member };
	}

	// Helper to build a minimal projection input
	function makeProjection(
		start_date: string,
		end_date: string,
		rotation_type: RotationType = 'onboard',
		crew_member: CrewMember = 'crew_a'
	): CreateRotationInput {
		return {
			user_id: 'test-user',
			start_date,
			end_date,
			rotation_type,
			crew_member,
			is_projected: true
		};
	}

	it('Case 1: no overlap → projection unchanged', () => {
		// confirmed Jan 1–5, projection Jan 10–28 → output is Jan 10–28 unchanged
		const projections = [makeProjection('2026-01-10', '2026-01-28')];
		const confirmed = [makeConfirmed('2026-01-01', '2026-01-05')];
		const result = trimProjectionsAgainstConfirmed(projections, confirmed);

		expect(result).toHaveLength(1);
		expect(result[0].start_date).toBe('2026-01-10');
		expect(result[0].end_date).toBe('2026-01-28');
		expect(result[0].rotation_type).toBe('onboard');
	});

	it('Case 2: overlap at start → trim start_date', () => {
		// confirmed Jan 1–10, projection Jan 1–28 → trimmed to Jan 11–28
		const projections = [makeProjection('2026-01-01', '2026-01-28')];
		const confirmed = [makeConfirmed('2026-01-01', '2026-01-10')];
		const result = trimProjectionsAgainstConfirmed(projections, confirmed);

		expect(result).toHaveLength(1);
		expect(result[0].start_date).toBe('2026-01-11');
		expect(result[0].end_date).toBe('2026-01-28');
		expect(result[0].rotation_type).toBe('onboard');
	});

	it('Case 3: overlap at end → trim end_date', () => {
		// confirmed Jan 20–28, projection Jan 1–28 → trimmed to Jan 1–19
		const projections = [makeProjection('2026-01-01', '2026-01-28')];
		const confirmed = [makeConfirmed('2026-01-20', '2026-01-28')];
		const result = trimProjectionsAgainstConfirmed(projections, confirmed);

		expect(result).toHaveLength(1);
		expect(result[0].start_date).toBe('2026-01-01');
		expect(result[0].end_date).toBe('2026-01-19');
		expect(result[0].rotation_type).toBe('onboard');
	});

	it('Case 4: overlap in middle → 2 fragments', () => {
		// confirmed Jan 10–15, projection Jan 1–28 → [Jan 1–9, Jan 16–28]
		const projections = [makeProjection('2026-01-01', '2026-01-28')];
		const confirmed = [makeConfirmed('2026-01-10', '2026-01-15')];
		const result = trimProjectionsAgainstConfirmed(projections, confirmed);

		expect(result).toHaveLength(2);
		// Left fragment: Jan 1 to day before blocker start (Jan 9)
		expect(result[0].start_date).toBe('2026-01-01');
		expect(result[0].end_date).toBe('2026-01-09');
		// Right fragment: day after blocker end (Jan 16) to Jan 28
		expect(result[1].start_date).toBe('2026-01-16');
		expect(result[1].end_date).toBe('2026-01-28');
		expect(result[0].rotation_type).toBe('onboard');
		expect(result[1].rotation_type).toBe('onboard');
	});

	it('Case 5: fully covered → eliminated (empty result)', () => {
		// confirmed Jan 1–28 covers projection Jan 5–20 entirely → []
		const projections = [makeProjection('2026-01-05', '2026-01-20')];
		const confirmed = [makeConfirmed('2026-01-01', '2026-01-28')];
		const result = trimProjectionsAgainstConfirmed(projections, confirmed);

		expect(result).toHaveLength(0);
	});

	it('Case 6: multiple blockers → multiple splits', () => {
		// confirmed [Jan 5–8, Jan 15–18], projection Jan 1–28 → [Jan 1–4, Jan 9–14, Jan 19–28]
		const projections = [makeProjection('2026-01-01', '2026-01-28')];
		const confirmed = [
			makeConfirmed('2026-01-05', '2026-01-08'),
			makeConfirmed('2026-01-15', '2026-01-18')
		];
		const result = trimProjectionsAgainstConfirmed(projections, confirmed);

		expect(result).toHaveLength(3);
		expect(result[0].start_date).toBe('2026-01-01');
		expect(result[0].end_date).toBe('2026-01-04');
		expect(result[1].start_date).toBe('2026-01-09');
		expect(result[1].end_date).toBe('2026-01-14');
		expect(result[2].start_date).toBe('2026-01-19');
		expect(result[2].end_date).toBe('2026-01-28');
	});

	it('Case 7: cross-type overlap → not trimmed', () => {
		// confirmed is 'off', projection is 'onboard' → projection unchanged
		const projections = [makeProjection('2026-01-01', '2026-01-28', 'onboard', 'crew_a')];
		const confirmed = [makeConfirmed('2026-01-10', '2026-01-15', 'off', 'crew_a')];
		const result = trimProjectionsAgainstConfirmed(projections, confirmed);

		expect(result).toHaveLength(1);
		expect(result[0].start_date).toBe('2026-01-01');
		expect(result[0].end_date).toBe('2026-01-28');
		expect(result[0].rotation_type).toBe('onboard');
	});

	it('Case 8: cross-crew overlap → not trimmed', () => {
		// confirmed is 'crew_b', projection is 'crew_a' → projection unchanged
		const projections = [makeProjection('2026-01-01', '2026-01-28', 'onboard', 'crew_a')];
		const confirmed = [makeConfirmed('2026-01-10', '2026-01-15', 'onboard', 'crew_b')];
		const result = trimProjectionsAgainstConfirmed(projections, confirmed);

		expect(result).toHaveLength(1);
		expect(result[0].start_date).toBe('2026-01-01');
		expect(result[0].end_date).toBe('2026-01-28');
		expect(result[0].rotation_type).toBe('onboard');
	});
});
