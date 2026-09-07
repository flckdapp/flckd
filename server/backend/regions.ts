import { file } from "bun";
import type { State } from "../shared/contracts";
import { regionFileSchema } from "./schemas";

export type RegionCatalog = State["regions"];

export async function loadRegions(path: string): Promise<RegionCatalog> {
  const parsed = regionFileSchema.parse(await file(path).json());
  return parsed.packs.map((pack) => ({ id: pack.id, name: pack.name, iso3166_2: pack.iso3166_2 }));
}

export function validateRegionSelection(regions: readonly string[], catalog: RegionCatalog): boolean {
  const valid = new Set(catalog.map((region) => region.id));
  const unique = new Set(regions);
  return unique.size === regions.length && regions.every((region) => valid.has(region));
}
