# Plataforma de transporte - Fase 1 (nucleo operativo)

Stack: TypeScript + React (Vite) + Supabase (Postgres, Auth, Edge Functions).

## Que incluye

- **Base de datos** (`supabase/migrations`): empresas, perfiles y roles, flota, disposiciones de asientos
  versionadas, recorridos, servicios, viajes, jornadas, contador de pasajeros y auditoria. Aislamiento
  entre empresas con RLS; la logica critica esta en funciones del servidor.
- **Panel admin** (`/admin`): operacion del dia, servicios, recorridos, flota, editor visual de
  disposiciones de asientos y conductores.
- **App del conductor** (`/conductor`): jornada, viajes del dia, iniciar y finalizar viaje, puntualidad y contador.

**Puntualidad:** el horario a cumplir es el de la carga del servicio (salida programada + minutos de cada parada).
Antes de la salida se muestra la cuenta regresiva (+11, +10 ... 0). Desde la hora programada el adelanto (+) o atraso (-)
lo calcula el GPS del telefono contra ese horario. La hora en que el chofer se conecto es solo referencia. No hay horas
estimadas. La posicion se usa en pantalla y no se guarda.

No incluye todavia: venta de pasajes, pagos, seguimiento GPS en el servidor, pasajero, QR, offline ni la app Android (Capacitor). Ver el plan por fases del prompt.

## Puesta en marcha

1. Crear un proyecto en Supabase.
2. Aplicar `0001_core.sql`, `0002_save_functions.sql`, `0003_route_catalog.sql`, `0004_route_ownership.sql` y `0005_service_departures.sql` , `0006_places_and_paths.sql`, `0007_day_types_and_start_service.sql` y `0008_route_times.sql` de `supabase/migrations` (SQL Editor o `supabase db push`).
3. Desplegar las funciones: `supabase functions deploy create-driver` y `supabase functions deploy create-company-admin`.
4. Copiar `web/.env.example` a `web/.env.local` y completar URL y anon key.
5. Crear el administrador general (una sola vez): crear el usuario en Authentication > Users y en el SQL Editor:
   ```sql
   insert into profiles (id, company_id, role, full_name)
   values ('<id del usuario>', null, 'platform_admin', 'Tu nombre');
   ```
   Desde ahi, las empresas y sus administradores se crean en el panel (`/admin`, seccion Empresas).
6. `cd web && npm install && npm run dev`.

## Quien hace que

- Administrador general (vos): crea empresas y su administrador, carga las localidades (origen/destino que elige el pasajero) y los recorridos (paradas con localidad y coordenadas, trazado por calles y puntos de paso), cada uno asignado en exclusiva a una empresa. No ve datos operativos de las empresas.
- Administrador de empresa: crea flota, disposiciones, conductores y servicios. Cada servicio (por ejemplo "214") agrupa varias salidas de ida y vuelta, cada una con su horario y sus días; los tiempos por parada se definen por sentido.

## Pruebas

- Logica de asientos y puntualidad: `cd web && npm test`
- Base de datos (Postgres local, sin Supabase): `supabase/tests/run.sh`
  Simula el esquema `auth` de Supabase y prueba aislamiento entre empresas, bloqueo y versionado de
  disposiciones, jornada, viajes y contador (idempotencia, conteo nunca negativo).

## Que NO esta probado

- Las pantallas contra un proyecto de Supabase real (solo se probo que compilan y cargan).
- Las Edge Functions `create-driver` y `create-company-admin` (necesitan un proyecto real).
- Los permisos de la tabla `auth.users` y la configuracion de roles propia de Supabase: el arnes local los imita.

## Pendiente conocido

- Franjas manana/tarde/noche fijas en la app del conductor (el prompt las pide configurables por empresa).
- Correccion de conteos por un administrador (hoy el contador solo agrega registros).
- Administracion general de la plataforma (rol `platform_admin`).
