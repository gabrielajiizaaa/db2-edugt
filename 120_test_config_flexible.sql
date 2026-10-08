-- EDUGT — Fase 2
-- Pruebas funcionales: procedimientos de configuracion flexible (admin)

-- Helper de limpieza: comisiones del instructor de prueba y politicas creadas
-- por estas pruebas (marcadas con deadline_days = 7777).
CREATE OR ALTER PROCEDURE dbo.test_cleanup_config
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM instructor_commissions
    WHERE instructor_id = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');
    DELETE FROM refund_policies WHERE deadline_days = 7777;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_config_nulls
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @admin    INT = (SELECT id FROM users WHERE email = 'admin.test@edugt.com');
    DECLARE @instr    INT = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');
    DECLARE @category INT = (SELECT id FROM categories WHERE name = 'Categoria Test');
    DECLARE @course   INT = (SELECT id FROM courses WHERE code = 'EDU-TEST-EXISTING');
    DECLARE @out INT, @err VARCHAR(2048);

    SET @err = NULL;
    BEGIN TRY EXEC dbo.sp_SetCategoryCommission @admin, @category, NULL; END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Config: comision de categoria NULL es rechazada', 'entre 0 y 100', @err;

    SET @err = NULL;
    BEGIN TRY EXEC dbo.sp_SetInstructorCommission @admin, @instr, NULL; END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Config: comision de instructor NULL es rechazada', 'entre 0 y 100', @err;

    SET @err = NULL;
    BEGIN TRY
        EXEC dbo.sp_CreateCohort @admin_id=@admin, @course_id=@course, @starts_at=NULL,
            @max_capacity=10, @new_cohort_id=@out OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Config: cohorte sin fecha de inicio es rechazada', 'fecha de inicio', @err;

    SET @err = NULL;
    BEGIN TRY
        EXEC dbo.sp_SetRefundPolicy @admin_id=@admin, @deadline_days=NULL,
            @max_progress_percent=30, @new_policy_id=@out OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Config: politica con plazo NULL es rechazada', 'mayor a cero', @err;

    SET @err = NULL;
    BEGIN TRY EXEC dbo.sp_SetCourseFeatured @admin, @course, NULL; END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Config: destacado NULL es rechazado', 'Debe indicar', @err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_config_comision_unica
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @admin INT = (SELECT id FROM users WHERE email = 'admin.test@edugt.com');
    DECLARE @instr INT = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');
    DECLARE @err VARCHAR(2048) = NULL;

    EXEC dbo.sp_SetInstructorCommission @admin, @instr, 20.00, '2026-01-01';
    EXEC dbo.sp_SetInstructorCommission @admin, @instr, 15.00, '2026-02-01';

    IF (SELECT COUNT(*) FROM instructor_commissions WHERE instructor_id = @instr AND valid_until IS NULL) = 1
        EXEC dbo.test_pass 'Config: al registrar una comision nueva se cierra la anterior';
    ELSE
        EXEC dbo.test_fail 'Config: al registrar una comision nueva se cierra la anterior';

    -- Insercion directa saltandose el SP: el indice filtrado la rechaza.
    BEGIN TRY
        INSERT INTO instructor_commissions (instructor_id, commission_percent, valid_from)
        VALUES (@instr, 10.00, '2026-03-01');
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Config: el motor impide dos comisiones abiertas por instructor',
        'UX_instructor_commissions_open', @err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_config_politica_unica
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @err VARCHAR(2048) = NULL;

    IF NOT EXISTS (SELECT 1 FROM refund_policies WHERE active = 1)
        INSERT INTO refund_policies (deadline_days, max_progress_percent, valid_from, active)
        VALUES (7777, 30.00, '2000-01-01', 1);

    BEGIN TRY
        INSERT INTO refund_policies (deadline_days, max_progress_percent, valid_from, active)
        VALUES (7777, 30.00, GETDATE(), 1);
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Config: el motor impide dos politicas de reembolso activas',
        'UX_refund_policies_active', @err;
END;

-- EJECUTAR TODOS
PRINT 'PRUEBAS FUNCIONALES: CONFIGURACION FLEXIBLE';

EXEC dbo.test_cleanup_config;
EXEC dbo.test_case_config_nulls;
EXEC dbo.test_case_config_comision_unica;
EXEC dbo.test_case_config_politica_unica;
EXEC dbo.test_cleanup_config;

PRINT '';
