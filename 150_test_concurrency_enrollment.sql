-- EDUGT — Fase 3
-- Pruebas de concurrencia Fase 3: cupo limitado y progreso simultaneo
-- Requiere haber ejecutado 140_test_progress.sql (usa sus helpers).
--
-- PARTE A: prueba automatica (una sesion) que verifica los invariantes.
-- PARTE B: guion para demostrar concurrencia REAL con varias ventanas de
--          DBeaver ejecutando al mismo tiempo con WAITFOR TIME.

-- PARTE A ----------------------------------------------------------------

-- Llena una cohorte de 3 lugares con 5 estudiantes: deben entrar exactamente 3,
-- los otros 2 reciben "Cupo lleno" sin cobro, y occupied_slots debe coincidir
-- con el numero real de inscripciones activas.
CREATE OR ALTER PROCEDURE dbo.test_case_concur_cupo
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @admin INT = (SELECT id FROM users WHERE email = 'admin.test@edugt.com');
    DECLARE @course INT, @cohort INT, @s INT, @enr INT, @bal DECIMAL(12,2), @i INT = 1;
    DECLARE @ok INT = 0, @full INT = 0, @start DATETIME = DATEADD(DAY, 7, GETDATE());
    DECLARE @email VARCHAR(200);

    EXEC dbo.test_make_course_full 'TEST Concur Cupo', 100.00, 0, @course OUTPUT;
    EXEC dbo.sp_CreateCohort @admin_id=@admin, @course_id=@course, @name='Cohorte 3 lugares',
        @starts_at=@start, @max_capacity=3, @new_cohort_id=@cohort OUTPUT;

    WHILE @i <= 5
    BEGIN
        SET @email = CONCAT('concur', @i, '.test@edugt.com');
        EXEC dbo.test_ensure_student @email, @s OUTPUT;
        EXEC dbo.sp_TopUpWallet @s, 100.00, @bal OUTPUT;
        BEGIN TRY
            EXEC dbo.sp_EnrollStudent @student_id=@s, @course_id=@course, @cohort_id=@cohort, @new_enrollment_id=@enr OUTPUT;
            SET @ok += 1;
        END TRY
        BEGIN CATCH
            IF ERROR_MESSAGE() LIKE '%Cupo lleno%' SET @full += 1;
        END CATCH
        SET @i += 1;
    END

    DECLARE @detail VARCHAR(200) = CONCAT('aceptadas=', @ok, ' cupo_lleno=', @full);
    IF @ok = 3 AND @full = 2
        EXEC dbo.test_pass 'Cupo: con 3 lugares y 5 solicitudes se aceptan 3 y se rechazan 2';
    ELSE
        EXEC dbo.test_fail 'Cupo: con 3 lugares y 5 solicitudes se aceptan 3 y se rechazan 2', @detail=@detail;

    IF (SELECT occupied_slots FROM cohorts WHERE id = @cohort)
       = (SELECT COUNT(*) FROM enrollments WHERE cohort_id = @cohort AND status = 'active')
        EXEC dbo.test_pass 'Cupo: occupied_slots coincide con las inscripciones activas';
    ELSE
        EXEC dbo.test_fail 'Cupo: occupied_slots coincide con las inscripciones activas';

    -- Los rechazados conservan su saldo completo.
    IF (SELECT COUNT(*) FROM wallets w JOIN users u ON u.id = w.user_id
        WHERE u.email LIKE 'concur%.test@edugt.com' AND w.balance = 100.00) = 2
        EXEC dbo.test_pass 'Cupo: a los rechazados no se les cobra';
    ELSE
        EXEC dbo.test_fail 'Cupo: a los rechazados no se les cobra';
END;

-- Billetera: dos inscripciones con saldo para una sola. La segunda debe
-- fallar por saldo insuficiente y el saldo nunca queda negativo.
CREATE OR ALTER PROCEDURE dbo.test_case_concur_billetera
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s INT, @c1 INT, @c2 INT, @enr INT, @bal DECIMAL(12,2), @err VARCHAR(2048) = NULL;
    EXEC dbo.test_ensure_student 'concurwallet.test@edugt.com', @s OUTPUT;
    EXEC dbo.test_make_course_full 'TEST Concur Billetera A', 150.00, 0, @c1 OUTPUT;
    EXEC dbo.test_make_course_full 'TEST Concur Billetera B', 150.00, 0, @c2 OUTPUT;
    EXEC dbo.sp_TopUpWallet @s, 200.00, @bal OUTPUT;

    EXEC dbo.sp_EnrollStudent @student_id=@s, @course_id=@c1, @new_enrollment_id=@enr OUTPUT;
    BEGIN TRY
        EXEC dbo.sp_EnrollStudent @student_id=@s, @course_id=@c2, @new_enrollment_id=@enr OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Billetera: la segunda inscripcion sin saldo suficiente se rechaza', 'Saldo insuficiente', @err;

    IF (SELECT balance FROM wallets WHERE user_id = @s) = 50.00
        EXEC dbo.test_pass 'Billetera: el saldo queda en 50.00 (nunca negativo)';
    ELSE
        EXEC dbo.test_fail 'Billetera: el saldo queda en 50.00 (nunca negativo)';
END;

-- Progreso: completar los 3 modulos en distinto orden produce 100% y cada
-- modulo registrado una sola vez (el progreso se recalcula, no se incrementa).
CREATE OR ALTER PROCEDURE dbo.test_case_concur_progreso
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s INT, @course INT, @enr INT, @pct DECIMAL(5,2), @code VARCHAR(30);
    EXEC dbo.test_make_progress_fixture 'TEST Concur Progreso', 'concurprogress.test@edugt.com', 0,
        @s OUTPUT, @course OUTPUT, @enr OUTPUT;

    EXEC dbo.test_study_module @enr, @s, 3, 20, @pct OUTPUT, @code OUTPUT;
    EXEC dbo.test_study_module @enr, @s, 1, 20, @pct OUTPUT, @code OUTPUT;
    EXEC dbo.test_study_module @enr, @s, 3, 20, @pct OUTPUT, @code OUTPUT;
    EXEC dbo.test_study_module @enr, @s, 2, 20, @pct OUTPUT, @code OUTPUT;

    IF (SELECT progress_percent FROM enrollments WHERE id = @enr) = 100
       AND (SELECT COUNT(*) FROM module_progress WHERE enrollment_id = @enr) = 3
        EXEC dbo.test_pass 'Progreso: orden distinto y reportes repetidos terminan en 100% con 3 modulos unicos';
    ELSE
        EXEC dbo.test_fail 'Progreso: orden distinto y reportes repetidos terminan en 100% con 3 modulos unicos';
END;

PRINT 'PRUEBAS DE CONCURRENCIA: INSCRIPCION Y PROGRESO';

EXEC dbo.test_ensure_refund_policy;
EXEC dbo.test_cleanup_courses 'TEST Concur%';
EXEC dbo.test_cleanup_test_wallets;
EXEC dbo.test_case_concur_cupo;
EXEC dbo.test_case_concur_billetera;
EXEC dbo.test_case_concur_progreso;
EXEC dbo.test_cleanup_courses 'TEST Concur%';
EXEC dbo.test_cleanup_test_wallets;

PRINT '';
PRINT 'Fin de la prueba automatica de concurrencia de Fase 3.';

-- PARTE B: DEMO MANUAL DE SESIONES SIMULTANEAS ---------------------------
--
-- DEMO 1: los ultimos lugares de una cohorte (caso "curso de inversiones").
--
-- PASO 0 (una sola vez, en cualquier ventana): cohorte de 4 lugares y 8
-- estudiantes con saldo.
--
--     EXEC dbo.test_ensure_refund_policy;
--     EXEC dbo.test_cleanup_courses 'TEST Demo%';
--     DECLARE @course INT, @cohort INT, @s INT, @bal DECIMAL(12,2), @i INT = 1, @email VARCHAR(200);
--     DECLARE @admin INT = (SELECT id FROM users WHERE email = 'admin.test@edugt.com');
--     DECLARE @start DATETIME = DATEADD(DAY, 7, GETDATE());
--     EXEC dbo.test_make_course_full 'TEST Demo Inversiones', 100.00, 0, @course OUTPUT;
--     EXEC dbo.sp_CreateCohort @admin_id=@admin, @course_id=@course, @name='Demo',
--          @starts_at=@start, @max_capacity=4, @new_cohort_id=@cohort OUTPUT;
--     WHILE @i <= 8
--     BEGIN
--         SET @email = CONCAT('demo', @i, '.test@edugt.com');
--         EXEC dbo.test_ensure_student @email, @s OUTPUT;
--         EXEC dbo.sp_TopUpWallet @s, 100.00, @bal OUTPUT;
--         SET @i += 1;
--     END
--     SELECT @course AS course_id, @cohort AS cohort_id;
--
-- PASO 1: abrir 8 ventanas. En cada una cambiar N (1..8) y la hora a
-- ~1 minuto en el futuro SEGUN EL RELOJ DEL SERVIDOR (SELECT GETDATE()):
--
--     DECLARE @enr INT, @s INT = (SELECT id FROM users WHERE email = 'demoN.test@edugt.com');
--     DECLARE @cohort INT = (SELECT TOP 1 ch.id FROM cohorts ch JOIN courses c ON c.id = ch.course_id
--                            WHERE c.title = 'TEST Demo Inversiones');
--     DECLARE @course INT = (SELECT course_id FROM cohorts WHERE id = @cohort);
--     WAITFOR TIME '14:30:00';
--     EXEC dbo.sp_EnrollStudent @student_id=@s, @course_id=@course, @cohort_id=@cohort,
--          @new_enrollment_id=@enr OUTPUT;
--
-- RESULTADO ESPERADO: exactamente 4 ventanas terminan sin error y 4 reciben
-- "Cupo lleno". Verificar:
--
--     SELECT ch.max_capacity, ch.occupied_slots,
--            (SELECT COUNT(*) FROM enrollments e WHERE e.cohort_id = ch.id AND e.status = 'active') AS activas
--     FROM cohorts ch JOIN courses c ON c.id = ch.course_id WHERE c.title = 'TEST Demo Inversiones';
--
-- DEMO 2: el mismo estudiante en dos dispositivos (actualizacion perdida).
--
-- PASO 0: inscribir a un estudiante y dejar estudiadas las lecciones de los
-- modulos 1 y 2 (sin marcar los modulos):
--
--     EXEC dbo.test_cleanup_courses 'TEST Demo Progreso%';
--     DECLARE @s INT, @course INT, @enr INT, @lesson INT;
--     EXEC dbo.test_make_progress_fixture 'TEST Demo Progreso', 'demoprogress.test@edugt.com', 0,
--          @s OUTPUT, @course OUTPUT, @enr OUTPUT;
--     DECLARE c CURSOR LOCAL FOR SELECT l.id FROM lessons l JOIN modules m ON m.id = l.module_id
--         WHERE m.course_id = @course AND m.order_index IN (1, 2);
--     OPEN c; FETCH NEXT FROM c INTO @lesson;
--     WHILE @@FETCH_STATUS = 0
--     BEGIN
--         EXEC dbo.test_study_lesson @enr, @s, @lesson, 20;
--         FETCH NEXT FROM c INTO @lesson;
--     END
--     CLOSE c; DEALLOCATE c;
--     SELECT @enr AS enrollment_id;
--
-- PASO 1: ventana "telefono" completa el modulo 1 y ventana "computadora" el
-- modulo 2, a la MISMA hora:
--
--     DECLARE @pct DECIMAL(5,2), @already BIT;
--     DECLARE @enr INT = (SELECT e.id FROM enrollments e JOIN courses c ON c.id = e.course_id
--                         WHERE c.title = 'TEST Demo Progreso');
--     DECLARE @s INT = (SELECT student_id FROM enrollments WHERE id = @enr);
--     DECLARE @module INT = (SELECT m.id FROM modules m JOIN enrollments e ON e.course_id = m.course_id
--                            WHERE e.id = @enr AND m.order_index = 1);   -- 2 en la otra ventana
--     WAITFOR TIME '14:35:00';
--     EXEC dbo.sp_CompleteModule @enr, @s, @module, @pct OUTPUT, @already OUTPUT;
--     SELECT @pct AS progreso_visto_por_esta_sesion;
--
-- RESULTADO ESPERADO: una sesion ve 33.33 y la otra 66.67; el progreso final
-- de la inscripcion es 66.67 (ningun avance se pierde). Si ambas ventanas usan
-- el MISMO modulo, una ve @already = 0 y la otra @already = 1, y module_progress
-- tiene una sola fila para ese modulo.
--
--     SELECT progress_percent FROM enrollments e JOIN courses c ON c.id = e.course_id
--     WHERE c.title = 'TEST Demo Progreso';
