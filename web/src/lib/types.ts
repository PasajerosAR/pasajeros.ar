import type { DayType } from './dayType';
import type { CellKind } from './seatGrid';

export type UserRole = 'platform_admin' | 'company_admin' | 'support' | 'driver';
export type VehicleStatus = 'available' | 'assigned' | 'in_service' | 'maintenance' | 'out_of_service' | 'retired';
export type TripStatus = 'scheduled' | 'in_progress' | 'completed' | 'cancelled';

export interface Profile {
  id: string;
  company_id: string | null;
  role: UserRole;
  full_name: string;
  dni: string | null;
  phone: string | null;
  active: boolean;
}

export interface Vehicle {
  id: string;
  company_id: string;
  kind: 'combi' | 'colectivo';
  internal_number: string;
  plate: string;
  brand: string | null;
  model: string | null;
  year: number | null;
  status: VehicleStatus;
  layout_id: string | null;
}

export interface SeatLayout {
  id: string;
  company_id: string;
  group_id: string;
  version: number;
  name: string;
  locked_at: string | null;
}

export interface Locality { id: string; name: string; province: string | null }
export interface Route {
  id: string; name: string; active: boolean; company_id: string | null;
  origin_place_id: string | null; destination_place_id: string | null;
  path: [number, number][] | null; via: { seg: number; lat: number; lng: number }[] | null;
}
export interface RouteStop {
  id: string; route_id: string; position: number; name: string; lat: number | null; lng: number | null; place_id: string | null;
}
export interface ServiceStop { service_id: string; route_stop_id: string; minutes_from_start: number; dwell_minutes: number }
export interface Company { id: string; name: string; active: boolean; created_at: string }
export interface Service { id: string; code: string; active: boolean }
export interface ServiceDeparture {
  id: string; service_id: string; route_id: string; departure_time: string; day_types: DayType[]; active: boolean;
}

export interface Trip {
  id: string;
  service_id: string;
  service_date: string;
  scheduled_departure: string;
  vehicle_id: string | null;
  layout_id: string | null;
  driver_id: string | null;
  status: TripStatus;
  started_at: string | null;
  ended_at: string | null;
  started_manually: boolean;
  start_reason: string | null;
}

export interface Shift { id: string; driver_id: string; started_at: string; ended_at: string | null }

export interface CountResult { onboard: number; capacity: number; over_capacity: boolean }

export type { CellKind };

export const STATUS_LABEL: Record<TripStatus, string> = {
  scheduled: 'Programado', in_progress: 'En viaje', completed: 'Finalizado', cancelled: 'Cancelado'
};
export const VEHICLE_STATUS_LABEL: Record<VehicleStatus, string> = {
  available: 'Disponible', assigned: 'Asignado', in_service: 'En servicio',
  maintenance: 'En mantenimiento', out_of_service: 'Fuera de servicio', retired: 'Baja definitiva'
};

export type IncidentKind = 'breakdown' | 'delay' | 'accident' | 'traffic' | 'other';
export const INCIDENT_LABEL: Record<IncidentKind, string> = {
  breakdown: 'Falla mecánica', delay: 'Demora', accident: 'Accidente', traffic: 'Tránsito o corte', other: 'Otra'
};
