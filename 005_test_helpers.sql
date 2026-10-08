
CREATE OR ALTER PROCEDURE dbo.test_pass
    @test_name VARCHAR(200)
AS
BEGIN
    PRINT CONCAT('PASS: ', @test_name);
END

CREATE OR ALTER PROCEDURE dbo.test_fail
    @test_name VARCHAR(200),
    @detail    VARCHAR(400) = NULL
AS
BEGIN
    DECLARE @msg VARCHAR(620) =
        CONCAT('FAIL: ', @test_name, CASE WHEN @detail IS NOT NULL THEN CONCAT(' -- ', @detail) ELSE '' END);
    RAISERROR('%s', 16, 1, @msg);
END

CREATE OR ALTER PROCEDURE dbo.test_expect_error
    @test_name      VARCHAR(200),
    @error_fragment VARCHAR(200),
    @actual_error   VARCHAR(2048)
AS
BEGIN
    IF @actual_error LIKE '%' + @error_fragment + '%'
        EXEC dbo.test_pass @test_name;
    ELSE
    BEGIN
        DECLARE @mismatch_detail VARCHAR(2400) =
            CONCAT('se esperaba error con "', @error_fragment, '" pero fue: ', @actual_error);
        EXEC dbo.test_fail @test_name, @detail = @mismatch_detail;
    END
END

-- Borra cursos de prueba cuyo titulo coincida con @title_like y todo lo que
-- depende de ellos (inscripciones, progreso, examenes, certificados, cobros).
CREATE OR ALTER PROCEDURE dbo.test_cleanup_courses
    @title_like VARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @courses TABLE (id INT);
    INSERT INTO @courses SELECT id FROM courses WHERE title LIKE @title_like;
    DECLARE @enr TABLE (id INT);
    INSERT INTO @enr SELECT id FROM enrollments WHERE course_id IN (SELECT id FROM @courses);

    DELETE FROM wallet_movements     WHERE enrollment_id IN (SELECT id FROM @enr);
    DELETE FROM certificates         WHERE enrollment_id IN (SELECT id FROM @enr);
    DELETE FROM exam_attempts        WHERE enrollment_id IN (SELECT id FROM @enr);
    DELETE FROM lesson_progress      WHERE enrollment_id IN (SELECT id FROM @enr);
    DELETE FROM module_progress      WHERE enrollment_id IN (SELECT id FROM @enr);
    DELETE FROM enrollments          WHERE id IN (SELECT id FROM @enr);
    DELETE FROM cohorts              WHERE course_id IN (SELECT id FROM @courses);
    DELETE FROM exams                WHERE course_id IN (SELECT id FROM @courses);
    DELETE FROM lessons WHERE module_id IN (SELECT m.id FROM modules m WHERE m.course_id IN (SELECT id FROM @courses));
    DELETE FROM modules              WHERE course_id IN (SELECT id FROM @courses);
    DELETE FROM course_prerequisites WHERE course_id IN (SELECT id FROM @courses) OR prerequisite_id IN (SELECT id FROM @courses);
    DELETE FROM course_instructors   WHERE course_id IN (SELECT id FROM @courses);
    DELETE FROM academic_reviews     WHERE course_id IN (SELECT id FROM @courses);
    DELETE FROM courses              WHERE id IN (SELECT id FROM @courses);
END

-- Borra las billeteras (y sus movimientos) y las notificaciones de inscripcion
-- y certificado de los usuarios de prueba (email '%.test@edugt.com').
-- Ejecutar despues de test_cleanup_courses.
CREATE OR ALTER PROCEDURE dbo.test_cleanup_test_wallets
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @users TABLE (id INT);
    INSERT INTO @users SELECT id FROM users WHERE email LIKE '%.test@edugt.com';

    DELETE FROM notifications WHERE user_id IN (SELECT id FROM @users) AND type IN ('enrolled', 'certificate');
    DELETE FROM wallet_movements WHERE wallet_id IN (SELECT id FROM wallets WHERE user_id IN (SELECT id FROM @users));
    DELETE FROM wallets WHERE user_id IN (SELECT id FROM @users);
END

-- Crea un curso disponible de 3 modulos; cada modulo tiene un video de 20 min
-- y un documento sin duracion (duracion esperada total: 60 min).
-- @with_exam = 1 agrega examen final (aprobacion 70, max 3 intentos).
CREATE OR ALTER PROCEDURE dbo.test_make_course_full
    @title     VARCHAR(200),
    @price     DECIMAL(10,2),
    @with_exam BIT,
    @course_id INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @category INT = (SELECT id FROM categories WHERE name = 'Categoria Test');
    DECLARE @instr    INT = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');

    INSERT INTO courses (code, title, description, category_id, price, status, published_at)
    VALUES (CONCAT('EDU-T3-', RIGHT(CONVERT(VARCHAR(36), NEWID()), 8)),
            @title, 'Curso de prueba Fase 3', @category, @price, 'available', GETDATE());
    SET @course_id = SCOPE_IDENTITY();

    INSERT INTO course_instructors (course_id, instructor_id, is_main, share_percent)
    VALUES (@course_id, @instr, 1, 100.00);

    DECLARE @modules TABLE (order_index INT, module_id INT);
    INSERT INTO modules (course_id, title, description, order_index)
    OUTPUT inserted.order_index, inserted.id INTO @modules (order_index, module_id)
    VALUES (@course_id, 'Modulo 1', NULL, 1), (@course_id, 'Modulo 2', NULL, 2), (@course_id, 'Modulo 3', NULL, 3);

    INSERT INTO lessons (module_id, title, type, content_url, duration_min, order_index)
    SELECT module_id, CONCAT('Video ', order_index), 'video', CONCAT('http://c/v', order_index), 20, 1 FROM @modules
    UNION ALL
    SELECT module_id, CONCAT('Lectura ', order_index), 'document', CONCAT('http://c/d', order_index), NULL, 2 FROM @modules;

    IF @with_exam = 1
        INSERT INTO exams (course_id, title, passing_score, max_attempts)
        VALUES (@course_id, 'Examen final', 70.00, 3);
END

-- Garantiza que exista una politica de reembolso vigente (7 dias, 20%),
-- requisito de sp_EnrollStudent para guardar el snapshot.
CREATE OR ALTER PROCEDURE dbo.test_ensure_refund_policy
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM refund_policies WHERE active = 1)
        INSERT INTO refund_policies (deadline_days, max_progress_percent, valid_from, valid_until, active)
        VALUES (7, 20.00, '2000-01-01', NULL, 1);
END

-- Crea (si no existe) un usuario estudiante de prueba.
CREATE OR ALTER PROCEDURE dbo.test_ensure_student
    @email VARCHAR(200),
    @id    INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM users WHERE email = @email)
        INSERT INTO users (first_name, last_name, email, password_hash, role)
        VALUES ('Student', 'Test', @email, 'hash', 'student');
    SET @id = (SELECT id FROM users WHERE email = @email);
END
