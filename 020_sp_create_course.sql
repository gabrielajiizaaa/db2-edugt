CREATE OR ALTER PROCEDURE dbo.sp_CreateCourse
    @instructor_id   INT,
    @title           VARCHAR(200),
    @description     VARCHAR(MAX) = NULL,
    @category_id     INT,
    @price           DECIMAL(10,2),
    @cover_image     VARCHAR(500) = NULL,
    @Modules         dbo.ModuleTableType READONLY,
    @Lessons         dbo.LessonTableType READONLY,
    @CoInstructors   dbo.CoInstructorTableType READONLY,
    @Prerequisites   dbo.PrerequisiteTableType READONLY,
    @new_course_id   INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Un NULL haria que las comparaciones de abajo den UNKNOWN y pasen la validacion,
    -- terminando en un error crudo 515 dentro de la transaccion.
    IF @title IS NULL OR LTRIM(RTRIM(@title)) = '' OR @price IS NULL OR @category_id IS NULL
        THROW 50017, 'El titulo, el precio y la categoria del curso son obligatorios.', 1;

    IF NOT EXISTS (SELECT 1 FROM users WHERE id = @instructor_id AND role = 'instructor')
        THROW 50001, 'El instructor especificado no existe o no tiene rol instructor.', 1;

    IF EXISTS (
        SELECT 1 FROM @CoInstructors ci
        WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.id = ci.instructor_id AND u.role = 'instructor')
    )
        THROW 50014, 'Uno o mas co-instructores no existen o no tienen rol instructor.', 1;

    IF EXISTS (SELECT instructor_id FROM @CoInstructors GROUP BY instructor_id HAVING COUNT(*) > 1)
        THROW 50018, 'Un instructor no puede aparecer mas de una vez en la lista de instructores.', 1;

    IF NOT EXISTS (SELECT 1 FROM categories WHERE id = @category_id)
        THROW 50002, 'La categoria especificada no existe.', 1;

    DECLARE @price_min DECIMAL(10,2), @price_max DECIMAL(10,2);
    SELECT @price_min = course_price_min, @price_max = course_price_max FROM platform_config WHERE id = 1;

    IF @price_min IS NULL
        THROW 50015, 'La plataforma no tiene configuracion de precios (platform_config). Contacte al administrador.', 1;

    IF @price < @price_min OR @price > @price_max
        THROW 50003, 'El precio del curso esta fuera del rango permitido por la plataforma.', 1;

    IF (SELECT COUNT(*) FROM @CoInstructors WHERE is_main = 1) <> 1
        THROW 50004, 'Debe existir exactamente un instructor principal (is_main = 1).', 1;

    IF NOT EXISTS (SELECT 1 FROM @CoInstructors WHERE is_main = 1 AND instructor_id = @instructor_id)
        THROW 50005, 'El instructor principal declarado en CoInstructors debe coincidir con @instructor_id.', 1;

    IF (SELECT COUNT(*) FROM @Modules) < 3
        THROW 50006, 'El curso debe tener al menos tres modulos.', 1;

    IF EXISTS (
        SELECT 1 FROM @Modules
        HAVING MIN(order_index) <> 1 OR MAX(order_index) <> COUNT(*) OR COUNT(DISTINCT order_index) <> COUNT(*)
    )
        THROW 50007, 'El order_index de los modulos debe ser secuencial de 1 a N sin huecos ni repetidos.', 1;

    IF EXISTS (
        SELECT m.order_index FROM @Modules m
        WHERE NOT EXISTS (
            SELECT 1 FROM @Lessons l WHERE l.module_order_index = m.order_index AND l.content_url IS NOT NULL
        )
    )
        THROW 50008, 'Cada modulo debe tener al menos una leccion con contenido valido (content_url).', 1;

    IF EXISTS (
        SELECT 1 FROM @Lessons l
        WHERE NOT EXISTS (SELECT 1 FROM @Modules m WHERE m.order_index = l.module_order_index)
    )
        THROW 50013, 'Una o mas lecciones referencian un modulo (module_order_index) que no existe en la lista de modulos.', 1;

       -- Nuevo check para lessons: validar tipo de lección
    IF EXISTS (SELECT 1 FROM @Lessons WHERE type NOT IN ('video', 'document', 'quiz'))
        THROW 50016, 'El tipo de leccion debe ser video, document o quiz.', 1;

    IF EXISTS (
        SELECT module_order_index FROM @Lessons
        GROUP BY module_order_index
        HAVING MIN(order_index) <> 1 OR MAX(order_index) <> COUNT(*) OR COUNT(DISTINCT order_index) <> COUNT(*)
    )
        THROW 50009, 'El order_index de las lecciones debe ser secuencial de 1 a N sin huecos dentro de cada modulo.', 1;

    IF (SELECT SUM(share_percent) FROM @CoInstructors) <> 100.00
        THROW 50010, 'La suma de share_percent de instructor principal y co-instructores debe ser exactamente 100.', 1;

    IF EXISTS (
        SELECT p.prerequisite_course_id FROM @Prerequisites p
        LEFT JOIN courses c ON c.id = p.prerequisite_course_id AND c.status = 'available'
        WHERE c.id IS NULL
    )
        THROW 50011, 'Todos los prerequisitos deben existir y estar en estado available.', 1;

    IF EXISTS (SELECT prerequisite_course_id FROM @Prerequisites GROUP BY prerequisite_course_id HAVING COUNT(*) > 1)
        THROW 50019, 'Un prerequisito no puede aparecer mas de una vez.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @year INT = YEAR(GETDATE());
        DECLARE @next_number INT;
		
        /*
        IF NOT EXISTS (SELECT 1 FROM course_code_sequences WHERE year = @year)
        INSERT INTO course_code_sequences (year, last_number) VALUES (@year, 0);
        
        UPDATE course_code_sequences WITH (UPDLOCK, ROWLOCK)
            SET last_number = last_number + 1,
                @next_number = last_number + 1
        WHERE year = @year;


        Imaginando que hay 5 sesiones en simultáneo arrancando el 2027 (cuando se renueva el code de cada curso).
		El lock llega hasta el update pero debería de bloquear antes de, para no dar mala experiencia al usuario
        
		*/
        
        INSERT INTO course_code_sequences (year, last_number)
        SELECT @year, 0
        WHERE NOT EXISTS (
            SELECT 1 FROM course_code_sequences WITH (UPDLOCK, HOLDLOCK) WHERE year = @year
        );

        UPDATE course_code_sequences WITH (UPDLOCK, ROWLOCK)
            SET last_number = last_number + 1,
                @next_number = last_number + 1
        WHERE year = @year;

      	/*
      	 
        DECLARE @code VARCHAR(20) = CONCAT('EDU-', @year, '-', RIGHT('00000' + CAST(@next_number AS VARCHAR(5)), 5));

		El @code puede tener overflow de truncamiento porque puede que llegue a un punto en donde ya no quepa en el varchar(5)
		sí tal vez no llegue nunca a esa cantidad de cursos en un año pero por diseño
		*/
        
        DECLARE @code VARCHAR(20) = CONCAT('EDU-', @year, '-', FORMAT(@next_number, 'D5'));
        
        
        INSERT INTO courses (code, title, description, category_id, price, cover_image, status, created_at)
        VALUES (@code, @title, @description, @category_id, @price, @cover_image, 'pending', GETDATE());

        SET @new_course_id = SCOPE_IDENTITY();

        DECLARE @ModuleMap TABLE (order_index INT PRIMARY KEY, module_id INT);

        MERGE INTO modules AS tgt
        USING @Modules AS src
        ON 1 = 0
        WHEN NOT MATCHED THEN
            INSERT (course_id, title, description, order_index)
            VALUES (@new_course_id, src.title, src.description, src.order_index)
        OUTPUT src.order_index, inserted.id INTO @ModuleMap (order_index, module_id);

        INSERT INTO lessons (module_id, title, type, content_url, duration_min, order_index)
        SELECT mm.module_id, l.title, l.type, l.content_url, l.duration_min, l.order_index
        FROM @Lessons l
        JOIN @ModuleMap mm ON mm.order_index = l.module_order_index;

        INSERT INTO course_instructors (course_id, instructor_id, is_main, share_percent)
        SELECT @new_course_id, instructor_id, is_main, share_percent FROM @CoInstructors;

        INSERT INTO course_prerequisites (course_id, prerequisite_id)
        SELECT @new_course_id, prerequisite_course_id FROM @Prerequisites;

        INSERT INTO notifications (user_id, type, subject, body)
        VALUES (@instructor_id, 'course_received', CONCAT('Recibimos tu curso: ', @title),
                CONCAT('Hola, recibimos tu curso "', @title, '" con codigo ', @code, '. Nuestro comite academico lo revisara pronto.'));

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
