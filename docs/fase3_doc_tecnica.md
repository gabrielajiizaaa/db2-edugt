# EduGT — Documentación Técnica, Fase 3

**Flujo de inscripción, progreso y certificados**
Justificación de aislamiento · Bloqueos · Evidencia de concurrencia · Referencia T-SQL

Base de Datos II · Universidad Rafael Landívar · 2026

---

## 1. Introducción

Este documento describe la solución T-SQL de la Fase 3 del proyecto EduGT: la inscripción de estudiantes con cobro contra billetera virtual, el registro de avance por lección y por módulo, la evaluación final y la emisión automática de certificados. Como en la Fase 2, toda la lógica vive en la capa de base de datos (procedimientos almacenados, funciones, restricciones e índices) y las garantías de integridad y concurrencia se hacen cumplir dentro del motor, sin confiar en validaciones externas.

## 2. Arquitectura del flujo

```
sp_TopUpWallet ──► sp_EnrollStudent ──► sp_StartLesson / sp_CompleteLesson
                                              │
                                              ▼
                                       sp_CompleteModule ──┐
                                                           ├──► sp_IssueCertificate (automático)
                         sp_RegisterExamAttempt ───────────┘
```

Estados de la inscripción (`enrollments.status`):

- **active**: inscrito, con acceso al contenido y avance en curso.
- **completed**: completó el 100 % de los módulos y aprobó el examen final si el curso lo tiene; ya tiene certificado.
- **refunded**: reembolsado (Fase 4); pierde el acceso al contenido.

Estados del certificado (`certificates.status`):

- **valid**: emitido sin observaciones.
- **pending_review**: emitido, pero marcado para revisión del comité académico por tiempo de estudio implausible.
- **revoked**: reservado para la revocación (Fase 4).

**Emisión automática.** El certificado no se pide a mano: lo emite, dentro de su misma transacción, el procedimiento que cierra la última condición pendiente.

- `sp_CompleteModule`, al completar el último módulo, si el curso no tiene examen o el examen ya está aprobado.
- `sp_RegisterExamAttempt`, al aprobar el examen, si ya estaba completado el 100 % de los módulos.

## 3. Justificación de aislamiento y bloqueos

**Nivel de aislamiento: READ COMMITTED (por defecto) en todos los procedimientos.** Cada punto de contención se resuelve con un mecanismo puntual sobre la fila exacta en disputa (UPDATE atómico condicionado, `UPDLOCK` o índice único filtrado). Subir a `SERIALIZABLE` agregaría bloqueos de rango sobre tablas muy concurridas (`enrollments`, `wallets`, `cohorts`) sin cerrar ningún riesgo adicional, y aumentaría la probabilidad de deadlocks.

### 3.1 Cupo limitado de cohortes: UPDATE atómico condicionado

**Riesgo.** Varios estudiantes compiten por los últimos lugares. Con "leer `occupied_slots`, comparar y luego escribir", dos sesiones leen el mismo valor y ambas se inscriben: hay sobreventa.

**Solución.** La comprobación y el incremento son una sola sentencia:

```sql
UPDATE cohorts
    SET occupied_slots = occupied_slots + 1
WHERE id = @cohort_id AND active = 1 AND occupied_slots < max_capacity;

IF @@ROWCOUNT = 0
    THROW 60010, 'Cupo lleno: la cohorte ya no tiene lugares disponibles.', 1;
```

El `UPDATE` toma un bloqueo exclusivo sobre la fila de la cohorte. Las solicitudes simultáneas se forman en fila. Cuando cada una obtiene el bloqueo, SQL Server reevalúa la condición contra el valor ya confirmado por la anterior. Así se cumplen las dos exigencias del enunciado:

- **Nunca se sobrevende.** La condición `occupied_slots < max_capacity` se evalúa con el valor real del momento.
- **Nunca se rechaza a alguien cuando todavía había lugar.** Se eligió este enfoque pesimista en lugar de un control optimista por versión. Con versión, una sesión que pierde la carrera falla aunque todavía quede cupo, y el estudiante tiene que reintentar.

`CK_cohorts_slots_max (occupied_slots <= max_capacity)` es la última garantía a nivel de motor. El incremento ocurre en la misma transacción que el `INSERT` de la inscripción, por lo que `occupied_slots` siempre coincide con las inscripciones reales: si algo falla después, el `ROLLBACK` devuelve el lugar.

### 3.2 Saldo de la billetera: UPDATE atómico condicionado

**Riesgo.** Dos operaciones simultáneas sobre la misma billetera, como dos inscripciones o una inscripción y un reembolso, leen el mismo saldo y lo dejan negativo, o se pierde uno de los cargos.

**Solución.** El mismo patrón:

```sql
UPDATE wallets
    SET balance = balance - @price, version = version + 1,
        @wallet_id = id, @new_balance = balance - @price
WHERE user_id = @student_id AND balance >= @price;

IF @@ROWCOUNT = 0
    THROW 60009, 'Saldo insuficiente: la billetera no cubre el precio del curso.', 1;
```

El saldo nunca se lee en una variable para escribirlo después: el cálculo `balance - @price` lo hace el motor sobre la fila bloqueada. El saldo resultante se captura en la misma sentencia y queda auditado en `wallet_movements.resulting_balance`. `CK_wallets_balance (balance >= 0)` es la última garantía.

### 3.3 Inscripción duplicada: índice único filtrado

Dos solicitudes simultáneas del mismo estudiante al mismo curso pasan ambas la validación previa. El índice `UX_enrollments_active (student_id, course_id) WHERE status = 'active'` del DDL rechaza la segunda inscripción (error 2601). El procedimiento traduce ese error a un mensaje de negocio. Como ocurre dentro de la transacción, el `ROLLBACK` deshace también el cobro y el cupo de la segunda sesión. Es el mismo patrón que `UX_reviews_active` de la Fase 2.

### 3.4 Orden de bloqueo: billetera → cohorte → inscripción

`sp_EnrollStudent` bloquea siempre en este orden: la fila de `wallets`, luego la de `cohorts` y por último inserta en `enrollments`. El reembolso de la Fase 4, que toca las mismas filas, debe respetar el mismo orden para evitar deadlocks entre inscripciones y reembolsos simultáneos.

### 3.5 Progreso desde varios dispositivos: UPDLOCK + recálculo + índice único

**Riesgos.**

1. **Actualización perdida:** el teléfono y la computadora leen `progress_percent = 33.33`, cada uno suma su módulo y ambos escriben 66.67; se pierde un avance.
2. **Módulo duplicado:** ambos registran el mismo módulo como completado.

**Solución en `sp_CompleteModule`.**

- **a. Serialización por inscripción.** Al iniciar la transacción, `SELECT ... FROM enrollments WITH (UPDLOCK, ROWLOCK)` forma en fila a las sesiones del mismo estudiante. La contención es mínima: solo compiten los dispositivos de un mismo estudiante, nunca estudiantes distintos.
- **b. Recálculo, no incremento.** `progress_percent` se recalcula siempre contando los módulos completados en `module_progress`. Nunca se suma sobre el valor leído. Aunque el orden de las sesiones varíe, el resultado final es correcto.
- **c. Unicidad a nivel de motor.** `UQ_mp_enrollment_module (enrollment_id, module_id)` impide registrar dos veces el mismo módulo.
- **d. Idempotencia.** Si el módulo ya estaba completado, el procedimiento no falla: devuelve `@already_completed = 1` y el progreso actual, y el segundo dispositivo simplemente se sincroniza.
- **e. Versión de fila.** `version` en `module_progress` y `lesson_progress` se incrementa en cada cambio de la fila.

Las lecciones siguen la misma idea. `sp_StartLesson` es idempotente: conserva el `started_at` original y, si dos dispositivos insertan a la vez, `UQ_lp_enrollment_lesson` rechaza el segundo. `sp_CompleteLesson` usa un `UPDATE ... WHERE completed_at IS NULL`, de modo que el segundo dispositivo no sobrescribe el momento del avance.

### 3.6 Correlativo de certificados sin huecos: UPDLOCK + HOLDLOCK

Mismo mecanismo que el código de curso de la Fase 2 (sección 3.1 de aquel documento), sobre la tabla `certificate_counters` (una fila por año):

```sql
INSERT INTO certificate_counters (year, last_number)
SELECT @year, 0
WHERE NOT EXISTS (SELECT 1 FROM certificate_counters WITH (UPDLOCK, HOLDLOCK) WHERE year = @year);

UPDATE certificate_counters WITH (UPDLOCK, ROWLOCK)
    SET last_number = last_number + 1, @next_number = last_number + 1
WHERE year = @year;
```

El número se asigna dentro de la transacción de emisión. Si esta se revierte, el contador vuelve atrás y no quedan huecos; no se usa `IDENTITY` ni `SEQUENCE`, que sí los dejan. El formato es `CERT-EDU-YYYY-NNNNN`. El año va dentro del código porque el contador se reinicia cada año: sin él, el primer certificado de cada año repetiría el mismo código y violaría `UQ_cert_code`.

### 3.7 Intentos de examen: UPDLOCK sobre la inscripción

`sp_RegisterExamAttempt` bloquea la fila de la inscripción antes de contar los intentos. Dos envíos simultáneos (doble clic o dos dispositivos) no pueden superar `max_attempts` ni registrar un intento después de haber aprobado. `UQ_ea_attempt` queda como red de seguridad.

**Orden de bloqueo del progreso:** `enrollments` → `certificate_counters`. Lo comparten `sp_CompleteModule`, `sp_RegisterExamAttempt` y `sp_IssueCertificate`.

### 3.8 Hallazgo durante las pruebas: deadlock por scan y su corrección

En la primera prueba de concurrencia real, 10 estudiantes terminaron su curso en el mismo instante y 9 sesiones cayeron en deadlock. El grafo de deadlock (`system_health`, evento `xml_deadlock_report`) mostró:

- Las dos sesiones tenían un bloqueo X sobre la fila de `module_progress` que cada una acababa de insertar.
- Ambas esperaban un bloqueo S sobre la fila de la otra.
- El conflicto estaba en la consulta que recalcula el progreso.

La consulta hacía un **scan** del índice clustered de `module_progress`, porque ningún índice cubría la columna `completed`. Al recorrer toda la tabla, cada sesión chocaba con la fila sin confirmar de la otra.

**Corrección:** índice cubriente

```sql
CREATE INDEX IX_module_progress_enrollment
    ON module_progress (enrollment_id) INCLUDE (module_id, completed);
```

Además, la consulta se simplificó para filtrar solo por `enrollment_id`. Con el Index Seek, cada sesión solo toca sus propias filas. Después de la corrección, 20 estudiantes simultáneos, repetido 4 veces, terminaron sin ningún deadlock (sección 6).

## 4. Detección de fraude por tiempo implausible

Al emitir el certificado se comparan dos sumas sobre las lecciones con `duration_min` definido:

- **Tiempo real:** `SUM(DATEDIFF(SECOND, started_at, completed_at)) / 60.0` en `lesson_progress`.
- **Tiempo esperado:** `SUM(lessons.duration_min)`.

Se suma el tiempo de cada lección en lugar de usar `MAX(completed_at) - MIN(started_at)`, que incluiría el tiempo muerto entre sesiones.

Si el tiempo real es menor al 50 % del esperado (`@min_time_ratio`), el certificado se emite con estado `pending_review`, el motivo se guarda en `review_reason` y se notifica a todos los académicos activos. Es el caso de "Kevin" del enunciado: un curso de una hora completado en minutos.

## 5. Referencia de procedimientos almacenados

### 5.1 sp_TopUpWallet

Acredita saldo a la billetera (recarga) y la crea si no existe. Registra un movimiento `credit` / `adjustment`.

| Error | Número | Condición |
|---|---|---|
| Usuario inválido | 59001 | El usuario no existe o no está activo. |
| Monto inválido | 59002 | El monto es nulo o no es mayor a cero. |

### 5.2 sp_EnrollStudent

Inscribe al estudiante cobrando contra su billetera y ocupando cupo de cohorte, en una sola transacción. Guarda el snapshot de la política de reembolso vigente y deja la inscripción con `settlement_status = 'pending'` (ingreso pendiente de liquidación para el instructor).

| Error | Número | Condición |
|---|---|---|
| Estudiante inválido | 60001 | No existe, no está activo o no tiene rol `student`. |
| Curso no disponible | 60002 | El curso no existe o no está en estado `available`. |
| Inscripción duplicada | 60003 | Ya tiene una inscripción activa en el curso (también por `UX_enrollments_active`). |
| Requisito previo | 60004 | No completó todos los cursos requisito. |
| Cohorte requerida | 60005 | El curso es en vivo y no se indicó cohorte. |
| Cohorte inválida | 60006 | La cohorte no existe, no es del curso, está inactiva o ya terminó. |
| Sin política | 60007 | No hay política de reembolso vigente. |
| Sin billetera | 60008 | El estudiante no tiene billetera. |
| Saldo insuficiente | 60009 | La billetera no cubre el precio vigente. |
| Cupo lleno | 60010 | La cohorte no tiene lugares en el momento exacto de la inscripción. |

### 5.3 sp_StartLesson / sp_CompleteLesson

Registran el inicio y el fin de una lección. Ambos son idempotentes.

| Error | Número | Condición |
|---|---|---|
| Inscripción ajena | 61001 | La inscripción no existe o no es del estudiante. |
| Sin acceso | 61002 | La inscripción fue reembolsada. |
| Lección inválida | 61003 | La lección no pertenece al curso. |
| Lección sin iniciar | 61004 | Se intentó completar una lección no iniciada. |

### 5.4 sp_CompleteModule

Marca el módulo completado, recalcula `progress_percent` y emite el certificado al llegar al 100 %.

| Error | Número | Condición |
|---|---|---|
| Inscripción ajena | 62001 | La inscripción no existe o no es del estudiante. |
| Inscripción inactiva | 62002 | La inscripción no está activa. |
| Módulo inválido | 62003 | El módulo no pertenece al curso. |
| Lecciones pendientes | 62004 | Faltan lecciones del módulo por completar. |
| Conflicto | 62005 | El módulo fue registrado por otra sesión en el mismo instante. |

### 5.5 sp_CreateExam

Registra el examen final del curso (opcional). Solo lo crea el instructor principal. Valores por defecto: nota mínima 70, máximo 3 intentos.

| Error | Número | Condición |
|---|---|---|
| Título vacío | 58001 | El título es obligatorio. |
| Curso inexistente | 58002 | El curso no existe. |
| Autorización | 58003 | Solo el instructor principal puede crear el examen. |
| Nota inválida | 58004 | `passing_score` fuera de 0–100. |
| Intentos inválidos | 58005 | `max_attempts` debe ser mayor a cero. |
| Examen existente | 58006 | El curso ya tiene examen final. |

### 5.6 sp_RegisterExamAttempt

Registra un intento del examen y, si aprueba con el 100 % de los módulos, emite el certificado.

| Error | Número | Condición |
|---|---|---|
| Nota inválida | 56001 | La nota no está entre 0 y 100. |
| Inscripción ajena | 56002 | La inscripción no existe o no es del estudiante. |
| Inscripción inactiva | 56003 | Solo una inscripción activa puede rendir el examen. |
| Sin examen | 56004 | El curso no tiene examen final. |
| Ya aprobado | 56005 | No se registran intentos después de aprobar. |
| Máximo de intentos | 56006 | Se alcanzó `max_attempts`. |
| Conflicto | 56007 | Otro intento simultáneo tomó el mismo número. |

### 5.7 sp_IssueCertificate

Emite el certificado con correlativo sin huecos y detección de fraude. Lo invocan automáticamente los SPs anteriores.

| Error | Número | Condición |
|---|---|---|
| Inscripción ajena | 57001 | La inscripción no existe o no es del estudiante. |
| Reembolsada | 57002 | La inscripción fue reembolsada. |
| Duplicado | 57003 / 57007 | Ya existe certificado (57007: emisión simultánea). |
| Examen no aprobado | 57005 | El curso tiene examen y no lo aprobó. |
| Módulos pendientes | 57006 | No completó el 100 % de los módulos. |

### 5.8 fn_ProgressHistory

Función con valores de tabla en línea (inline TVF): devuelve el historial de progreso de una inscripción. Hay una fila por lección, con su momento de inicio y fin, los minutos invertidos y el estado de su módulo. Es la base del "historial de progreso" y de las horas de estudio del reporte de actividad (Fase 4).

```sql
SELECT * FROM dbo.fn_ProgressHistory(@enrollment_id) ORDER BY module_order, lesson_order;
```

### 5.9 Cambios a objetos de la Fase 2

- `sp_CreateCourse`: valida título, precio y categoría no nulos (50017), instructores repetidos (50018) y prerrequisitos repetidos (50019).
- `sp_SetInstructorCommission` / `sp_SetRefundPolicy`: validan nulos y serializan a los administradores con `UPDLOCK + HOLDLOCK`. Traducen los conflictos simultáneos a 55105 / 55305.
- `sp_CreateCohort` (55205) y `sp_SetCourseFeatured` (55404): validan nulos.
- DDL:
  - Índices `UX_instructor_commissions_open` y `UX_refund_policies_active`: a nivel de motor, solo puede haber una comisión abierta por instructor y una política vigente.
  - Nuevo índice `IX_module_progress_enrollment` (sección 3.8).
  - `TEXT` cambia a `VARCHAR(MAX)`.
  - Se eliminó el índice redundante `IX_enrollments_course`.

## 6. Estrategia de pruebas y evidencia de concurrencia

### 6.1 Pruebas funcionales automáticas

Usan los mismos helpers de la Fase 2 (`test_pass`, `test_fail`, `test_expect_error`).

| Archivo | Cubre | Casos |
|---|---|---|
| `110_test_exam_certificate.sql` | Examen, intentos, emisión automática, fraude, correlativo, examen opcional | 25 |
| `120_test_config_flexible.sql` | Validaciones de nulos e índices de unicidad de configuración | 8 |
| `130_test_enrollment.sql` | Billetera, inscripción, saldo, requisitos, cohortes, reversión sin rastro | 18 |
| `140_test_progress.sql` | Lecciones, módulos, idempotencia, certificado automático, historial | 12 |
| `150_test_concurrency_enrollment.sql` | Invariantes de cupo, billetera y progreso, más el guion de demo manual | 6 |

Resultado de la suite completa (Fases 2 y 3, del archivo 080 al 150): **96 PASS, 0 FAIL**, y el mismo resultado al ejecutarla dos veces seguidas.

### 6.2 Concurrencia real: sesiones simultáneas

Cada escenario se ejecutó con N sesiones `sqlcmd` independientes en paralelo, sincronizadas con `WAITFOR TIME` contra el reloj del servidor. La batería completa se repitió 4 veces con resultados idénticos y **0 errores o deadlocks**.

**Escenario 1: 30 estudiantes por los últimos 4 cupos** (cohorte de 50 con 46 ocupados).

```
  26 CUPO LLENO
   4 INSCRITO
max_capacity=50 occupied_slots=50 inscripciones_activas_nuevas=4 cobros=4 billeteras_intactas=26
```

No hubo sobreventa, cada lugar libre se otorgó y a ninguno de los 26 rechazados se le cobró.

**Escenario 2: una billetera con Q250, cinco inscripciones simultáneas de Q100.**

```
curso 1: INSCRITO
curso 2: Saldo insuficiente: la billetera no cubre el precio del curso.
curso 3: Saldo insuficiente: la billetera no cubre el precio del curso.
curso 4: INSCRITO
curso 5: Saldo insuficiente: la billetera no cubre el precio del curso.
saldo_final=50.00 debitos=2 ultimo_resulting_balance=50.00
```

Se hicieron exactamente los dos cobros posibles y el saldo nunca quedó negativo.

**Escenario 3: teléfono y computadora del mismo estudiante.**

```
telefono (modulo 1): progreso visto=33.33 ya_completado=0
computadora (modulo 2): progreso visto=66.67 ya_completado=0
telefono (modulo 3): progreso visto=100.00 ya_completado=0
computadora (modulo 3): progreso visto=100.00 ya_completado=1
progreso_final=100.00 filas_module_progress=3 certificado=CERT-EDU-2026-00011 valid estado=completed
```

No hubo actualización perdida: dos módulos distintos a la vez terminan en 66.67 y no en 33.33. El mismo módulo reportado a la vez queda una sola vez, y el certificado se emitió automáticamente.

**Escenario 4: 20 estudiantes completan su último módulo en el mismo instante.**

```
certificados=20 distintos=20 min=12 max=31 sin_huecos=SI
```

Se emitieron 20 certificados con correlativos consecutivos, únicos y sin huecos.

### 6.3 Demo en vivo

`150_test_concurrency_enrollment.sql`, parte B, contiene el guion para reproducir los escenarios 1 y 3 en clase con varias ventanas de DBeaver sincronizadas con `WAITFOR TIME`, igual que la demo de revisión académica de la Fase 2. La hora debe tomarse del reloj del servidor (`SELECT GETDATE()`), que puede estar en UTC.

## 7. Orden de ejecución

1. `edugt_ddl.sql`
2. Del `000` al `078` (tipos, helpers, datos de prueba, procedimientos y función)
3. Pruebas del `080` al `150`

Si se ejecutan con `sqlcmd` en lugar de DBeaver, usar la opción `-I` (`QUOTED_IDENTIFIER ON`). Sin ella falla la creación de los índices filtrados.
