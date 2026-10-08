
-- sp_CreateExam
-- Registra el examen final de un curso. Lo crea el instructor principal.
-- Cada curso tiene un unico examen final (UQ_exams_course); si dos sesiones lo
-- crean a la vez, la segunda falla con 2627 y se traduce a un mensaje claro.
-- passing_score y max_attempts son opcionales y toman los defaults de la
-- tabla (70 y 3) cuando no se indican.

CREATE OR ALTER PROCEDURE dbo.sp_CreateExam
    @instructor_id INT,
    @course_id     INT,
    @title         VARCHAR(200),
    @passing_score DECIMAL(5,2) = NULL,
    @max_attempts  INT = NULL,
    @new_exam_id   INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @title IS NULL OR LTRIM(RTRIM(@title)) = ''
        THROW 58001, 'El titulo del examen es obligatorio.', 1;

    IF NOT EXISTS (SELECT 1 FROM courses WHERE id = @course_id)
        THROW 58002, 'El curso especificado no existe.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM course_instructors
        WHERE course_id = @course_id AND instructor_id = @instructor_id AND is_main = 1
    )
        THROW 58003, 'Solo el instructor principal puede crear el examen final del curso.', 1;

    IF @passing_score IS NOT NULL AND (@passing_score < 0 OR @passing_score > 100)
        THROW 58004, 'La nota minima de aprobacion debe estar entre 0 y 100.', 1;

    IF @max_attempts IS NOT NULL AND @max_attempts <= 0
        THROW 58005, 'El maximo de intentos debe ser mayor a cero.', 1;

    IF EXISTS (SELECT 1 FROM exams WHERE course_id = @course_id)
        THROW 58006, 'El curso ya tiene un examen final.', 1;

    BEGIN TRY
        INSERT INTO exams (course_id, title, passing_score, max_attempts)
        VALUES (@course_id, @title, ISNULL(@passing_score, 70), ISNULL(@max_attempts, 3));

        SET @new_exam_id = SCOPE_IDENTITY();
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() IN (2601, 2627)
            THROW 58006, 'El curso ya tiene un examen final.', 1;

        THROW;
    END CATCH
END
