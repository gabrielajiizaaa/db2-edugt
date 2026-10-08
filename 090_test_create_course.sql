
-- EDUGT — Fase 2
-- Pruebas funcionales: sp_CreateCourse DBeaver

-- Helper de limpieza
CREATE OR ALTER PROCEDURE dbo.test_cleanup_created_courses
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ids TABLE (id INT);
    INSERT INTO @ids SELECT id FROM courses WHERE title LIKE 'TEST CreateCourse%';
    DELETE FROM course_prerequisites WHERE course_id IN (SELECT id FROM @ids);
    DELETE FROM lessons WHERE module_id IN (SELECT m.id FROM modules m WHERE m.course_id IN (SELECT id FROM @ids));
    DELETE FROM modules WHERE course_id IN (SELECT id FROM @ids);
    DELETE FROM course_instructors WHERE course_id IN (SELECT id FROM @ids);
    DELETE FROM notifications WHERE subject LIKE '%TEST CreateCourse%';
    DELETE FROM courses WHERE id IN (SELECT id FROM @ids);
END;

-- Encapsulamos cada caso en un SP para aislar los TVPs sin necesitar GO
CREATE OR ALTER PROCEDURE dbo.test_case_create_course_ok
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @instructor INT = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');
    DECLARE @coinstr    INT = (SELECT id FROM users WHERE email = 'coinstructor.test@edugt.com');
    DECLARE @category   INT = (SELECT id FROM categories WHERE name = 'Categoria Test');
    DECLARE @new_id INT, @err VARCHAR(2048) = NULL;

    DECLARE @Modules dbo.ModuleTableType;
    INSERT INTO @Modules (order_index, title, description) VALUES
        (1,'Modulo 1','Intro'),(2,'Modulo 2','Desarrollo'),(3,'Modulo 3','Cierre');

    DECLARE @Lessons dbo.LessonTableType;
    INSERT INTO @Lessons (module_order_index, order_index, title, type, content_url, duration_min) VALUES
        (1,1,'Leccion 1.1','video','http://c/1',10),
        (2,1,'Leccion 2.1','video','http://c/2',12),
        (3,1,'Leccion 3.1','document','http://c/3',8);

    DECLARE @Co dbo.CoInstructorTableType;
    INSERT INTO @Co (instructor_id, share_percent, is_main) VALUES
        (@instructor,70.00,1),(@coinstr,30.00,0);

    DECLARE @Prereq dbo.PrerequisiteTableType;

    BEGIN TRY
        EXEC dbo.sp_CreateCourse
            @instructor_id=@instructor, @title='TEST CreateCourse OK',
            @description='Curso valido', @category_id=@category, @price=100.00,
            @Modules=@Modules, @Lessons=@Lessons, @CoInstructors=@Co,
            @Prerequisites=@Prereq, @new_course_id=@new_id OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH

    IF @err IS NULL AND @new_id IS NOT NULL
        EXEC dbo.test_pass 'Caso valido: curso creado correctamente';
    ELSE
        EXEC dbo.test_fail 'Caso valido: curso creado correctamente', @detail=@err;

    IF EXISTS (SELECT 1 FROM courses WHERE id=@new_id AND status='pending' AND code LIKE 'EDU-%')
        EXEC dbo.test_pass 'Curso creado queda en estado pending con codigo EDU-';
    ELSE
        EXEC dbo.test_fail 'Curso creado queda en estado pending con codigo EDU-';

    IF (SELECT COUNT(*) FROM modules WHERE course_id=@new_id) = 3
        EXEC dbo.test_pass 'Curso creado tiene sus 3 modulos';
    ELSE
        EXEC dbo.test_fail 'Curso creado tiene sus 3 modulos';
END;

CREATE OR ALTER PROCEDURE dbo.test_case_create_course_2mods
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @instructor INT = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');
    DECLARE @category   INT = (SELECT id FROM categories WHERE name = 'Categoria Test');
    DECLARE @new_id INT, @err VARCHAR(2048) = NULL;

    DECLARE @Modules dbo.ModuleTableType;
    INSERT INTO @Modules (order_index, title, description) VALUES (1,'M1','a'),(2,'M2','b');

    DECLARE @Lessons dbo.LessonTableType;
    INSERT INTO @Lessons (module_order_index, order_index, title, type, content_url, duration_min) VALUES
        (1,1,'L','video','http://c/1',10),(2,1,'L','video','http://c/2',10);

    DECLARE @Co dbo.CoInstructorTableType;
    INSERT INTO @Co (instructor_id, share_percent, is_main) VALUES (@instructor,100.00,1);

    DECLARE @Prereq dbo.PrerequisiteTableType;

    BEGIN TRY
        EXEC dbo.sp_CreateCourse
            @instructor_id=@instructor, @title='TEST CreateCourse 2mods',
            @category_id=@category, @price=100.00,
            @Modules=@Modules, @Lessons=@Lessons, @CoInstructors=@Co,
            @Prerequisites=@Prereq, @new_course_id=@new_id OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Rechaza curso con menos de 3 modulos','al menos tres modulos',@err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_create_course_share90
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @instructor INT = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');
    DECLARE @coinstr    INT = (SELECT id FROM users WHERE email = 'coinstructor.test@edugt.com');
    DECLARE @category   INT = (SELECT id FROM categories WHERE name = 'Categoria Test');
    DECLARE @new_id INT, @err VARCHAR(2048) = NULL;

    DECLARE @Modules dbo.ModuleTableType;
    INSERT INTO @Modules (order_index,title,description) VALUES (1,'M1','a'),(2,'M2','b'),(3,'M3','c');
    DECLARE @Lessons dbo.LessonTableType;
    INSERT INTO @Lessons (module_order_index,order_index,title,type,content_url,duration_min) VALUES
        (1,1,'L','video','http://c/1',10),(2,1,'L','video','http://c/2',10),(3,1,'L','video','http://c/3',10);
    DECLARE @Co dbo.CoInstructorTableType;
    INSERT INTO @Co (instructor_id,share_percent,is_main) VALUES (@instructor,70.00,1),(@coinstr,20.00,0);
    DECLARE @Prereq dbo.PrerequisiteTableType;

    BEGIN TRY
        EXEC dbo.sp_CreateCourse
            @instructor_id=@instructor, @title='TEST CreateCourse share90',
            @category_id=@category, @price=100.00,
            @Modules=@Modules, @Lessons=@Lessons, @CoInstructors=@Co,
            @Prerequisites=@Prereq, @new_course_id=@new_id OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Rechaza share_percent que no suma 100','exactamente 100',@err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_create_course_precio
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @instructor INT = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');
    DECLARE @category   INT = (SELECT id FROM categories WHERE name = 'Categoria Test');
    DECLARE @new_id INT, @err VARCHAR(2048) = NULL;

    DECLARE @Modules dbo.ModuleTableType;
    INSERT INTO @Modules (order_index,title,description) VALUES (1,'M1','a'),(2,'M2','b'),(3,'M3','c');
    DECLARE @Lessons dbo.LessonTableType;
    INSERT INTO @Lessons (module_order_index,order_index,title,type,content_url,duration_min) VALUES
        (1,1,'L','video','http://c/1',10),(2,1,'L','video','http://c/2',10),(3,1,'L','video','http://c/3',10);
    DECLARE @Co dbo.CoInstructorTableType;
    INSERT INTO @Co (instructor_id,share_percent,is_main) VALUES (@instructor,100.00,1);
    DECLARE @Prereq dbo.PrerequisiteTableType;

    BEGIN TRY
        EXEC dbo.sp_CreateCourse
            @instructor_id=@instructor, @title='TEST CreateCourse precio',
            @category_id=@category, @price=999999.00,
            @Modules=@Modules, @Lessons=@Lessons, @CoInstructors=@Co,
            @Prerequisites=@Prereq, @new_course_id=@new_id OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Rechaza precio fuera de rango','fuera del rango',@err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_create_course_huecomod
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @instructor INT = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');
    DECLARE @category   INT = (SELECT id FROM categories WHERE name = 'Categoria Test');
    DECLARE @new_id INT, @err VARCHAR(2048) = NULL;

    DECLARE @Modules dbo.ModuleTableType;
    INSERT INTO @Modules (order_index,title,description) VALUES (1,'M1','a'),(2,'M2','b'),(4,'M4','hueco');
    DECLARE @Lessons dbo.LessonTableType;
    INSERT INTO @Lessons (module_order_index,order_index,title,type,content_url,duration_min) VALUES
        (1,1,'L','video','http://c/1',10),(2,1,'L','video','http://c/2',10),(4,1,'L','video','http://c/4',10);
    DECLARE @Co dbo.CoInstructorTableType;
    INSERT INTO @Co (instructor_id,share_percent,is_main) VALUES (@instructor,100.00,1);
    DECLARE @Prereq dbo.PrerequisiteTableType;

    BEGIN TRY
        EXEC dbo.sp_CreateCourse
            @instructor_id=@instructor, @title='TEST CreateCourse huecomod',
            @category_id=@category, @price=100.00,
            @Modules=@Modules, @Lessons=@Lessons, @CoInstructors=@Co,
            @Prerequisites=@Prereq, @new_course_id=@new_id OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Rechaza modulos con order_index no secuencial','secuencial',@err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_create_course_sincontenido
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @instructor INT = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');
    DECLARE @category   INT = (SELECT id FROM categories WHERE name = 'Categoria Test');
    DECLARE @new_id INT, @err VARCHAR(2048) = NULL;

    DECLARE @Modules dbo.ModuleTableType;
    INSERT INTO @Modules (order_index,title,description) VALUES (1,'M1','a'),(2,'M2','b'),(3,'M3','c');
    DECLARE @Lessons dbo.LessonTableType;
    INSERT INTO @Lessons (module_order_index,order_index,title,type,content_url,duration_min) VALUES
        (1,1,'L','video','http://c/1',10),(2,1,'L','video','http://c/2',10),(3,1,'L','video',NULL,10);
    DECLARE @Co dbo.CoInstructorTableType;
    INSERT INTO @Co (instructor_id,share_percent,is_main) VALUES (@instructor,100.00,1);
    DECLARE @Prereq dbo.PrerequisiteTableType;

    BEGIN TRY
        EXEC dbo.sp_CreateCourse
            @instructor_id=@instructor, @title='TEST CreateCourse sincontenido',
            @category_id=@category, @price=100.00,
            @Modules=@Modules, @Lessons=@Lessons, @CoInstructors=@Co,
            @Prerequisites=@Prereq, @new_course_id=@new_id OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Rechaza modulo sin leccion con contenido','contenido valido',@err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_create_course_tipomalo
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @instructor INT = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');
    DECLARE @category   INT = (SELECT id FROM categories WHERE name = 'Categoria Test');
    DECLARE @new_id INT, @err VARCHAR(2048) = NULL;

    DECLARE @Modules dbo.ModuleTableType;
    INSERT INTO @Modules (order_index,title,description) VALUES (1,'M1','a'),(2,'M2','b'),(3,'M3','c');
    DECLARE @Lessons dbo.LessonTableType;
    INSERT INTO @Lessons (module_order_index,order_index,title,type,content_url,duration_min) VALUES
        (1,1,'L','video','http://c/1',10),(2,1,'L','audio','http://c/2',10),(3,1,'L','video','http://c/3',10);
    DECLARE @Co dbo.CoInstructorTableType;
    INSERT INTO @Co (instructor_id,share_percent,is_main) VALUES (@instructor,100.00,1);
    DECLARE @Prereq dbo.PrerequisiteTableType;

    BEGIN TRY
        EXEC dbo.sp_CreateCourse
            @instructor_id=@instructor, @title='TEST CreateCourse tipomalo',
            @category_id=@category, @price=100.00,
            @Modules=@Modules, @Lessons=@Lessons, @CoInstructors=@Co,
            @Prerequisites=@Prereq, @new_course_id=@new_id OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Rechaza tipo de leccion invalido','video, document o quiz',@err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_create_course_2main
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @instructor INT = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');
    DECLARE @coinstr    INT = (SELECT id FROM users WHERE email = 'coinstructor.test@edugt.com');
    DECLARE @category   INT = (SELECT id FROM categories WHERE name = 'Categoria Test');
    DECLARE @new_id INT, @err VARCHAR(2048) = NULL;

    DECLARE @Modules dbo.ModuleTableType;
    INSERT INTO @Modules (order_index,title,description) VALUES (1,'M1','a'),(2,'M2','b'),(3,'M3','c');
    DECLARE @Lessons dbo.LessonTableType;
    INSERT INTO @Lessons (module_order_index,order_index,title,type,content_url,duration_min) VALUES
        (1,1,'L','video','http://c/1',10),(2,1,'L','video','http://c/2',10),(3,1,'L','video','http://c/3',10);
    DECLARE @Co dbo.CoInstructorTableType;
    INSERT INTO @Co (instructor_id,share_percent,is_main) VALUES (@instructor,50.00,1),(@coinstr,50.00,1);
    DECLARE @Prereq dbo.PrerequisiteTableType;

    BEGIN TRY
        EXEC dbo.sp_CreateCourse
            @instructor_id=@instructor, @title='TEST CreateCourse 2main',
            @category_id=@category, @price=100.00,
            @Modules=@Modules, @Lessons=@Lessons, @CoInstructors=@Co,
            @Prerequisites=@Prereq, @new_course_id=@new_id OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Rechaza mas de un instructor principal','exactamente un instructor principal',@err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_create_course_prereqmalo
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @instructor INT = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');
    DECLARE @category   INT = (SELECT id FROM categories WHERE name = 'Categoria Test');
    DECLARE @new_id INT, @err VARCHAR(2048) = NULL;

    DECLARE @Modules dbo.ModuleTableType;
    INSERT INTO @Modules (order_index,title,description) VALUES (1,'M1','a'),(2,'M2','b'),(3,'M3','c');
    DECLARE @Lessons dbo.LessonTableType;
    INSERT INTO @Lessons (module_order_index,order_index,title,type,content_url,duration_min) VALUES
        (1,1,'L','video','http://c/1',10),(2,1,'L','video','http://c/2',10),(3,1,'L','video','http://c/3',10);
    DECLARE @Co dbo.CoInstructorTableType;
    INSERT INTO @Co (instructor_id,share_percent,is_main) VALUES (@instructor,100.00,1);
    DECLARE @Prereq dbo.PrerequisiteTableType;
    INSERT INTO @Prereq (prerequisite_course_id) VALUES (999999999);

    BEGIN TRY
        EXEC dbo.sp_CreateCourse
            @instructor_id=@instructor, @title='TEST CreateCourse prereqmalo',
            @category_id=@category, @price=100.00,
            @Modules=@Modules, @Lessons=@Lessons, @CoInstructors=@Co,
            @Prerequisites=@Prereq, @new_course_id=@new_id OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Rechaza prerequisito inexistente o no disponible','prerequisitos deben existir',@err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_create_course_precionull
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @instructor INT = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');
    DECLARE @category   INT = (SELECT id FROM categories WHERE name = 'Categoria Test');
    DECLARE @new_id INT, @err VARCHAR(2048) = NULL;

    DECLARE @Modules dbo.ModuleTableType;
    INSERT INTO @Modules (order_index,title,description) VALUES (1,'M1','a'),(2,'M2','b'),(3,'M3','c');
    DECLARE @Lessons dbo.LessonTableType;
    INSERT INTO @Lessons (module_order_index,order_index,title,type,content_url,duration_min) VALUES
        (1,1,'L','video','http://c/1',10),(2,1,'L','video','http://c/2',10),(3,1,'L','video','http://c/3',10);
    DECLARE @Co dbo.CoInstructorTableType;
    INSERT INTO @Co (instructor_id,share_percent,is_main) VALUES (@instructor,100.00,1);
    DECLARE @Prereq dbo.PrerequisiteTableType;

    BEGIN TRY
        EXEC dbo.sp_CreateCourse
            @instructor_id=@instructor, @title='TEST CreateCourse precionull',
            @category_id=@category, @price=NULL,
            @Modules=@Modules, @Lessons=@Lessons, @CoInstructors=@Co,
            @Prerequisites=@Prereq, @new_course_id=@new_id OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Rechaza precio NULL con mensaje de negocio','son obligatorios',@err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_create_course_instrdup
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @instructor INT = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');
    DECLARE @category   INT = (SELECT id FROM categories WHERE name = 'Categoria Test');
    DECLARE @new_id INT, @err VARCHAR(2048) = NULL;

    DECLARE @Modules dbo.ModuleTableType;
    INSERT INTO @Modules (order_index,title,description) VALUES (1,'M1','a'),(2,'M2','b'),(3,'M3','c');
    DECLARE @Lessons dbo.LessonTableType;
    INSERT INTO @Lessons (module_order_index,order_index,title,type,content_url,duration_min) VALUES
        (1,1,'L','video','http://c/1',10),(2,1,'L','video','http://c/2',10),(3,1,'L','video','http://c/3',10);
    DECLARE @Co dbo.CoInstructorTableType;
    INSERT INTO @Co (instructor_id,share_percent,is_main) VALUES (@instructor,50.00,1),(@instructor,50.00,0);
    DECLARE @Prereq dbo.PrerequisiteTableType;

    BEGIN TRY
        EXEC dbo.sp_CreateCourse
            @instructor_id=@instructor, @title='TEST CreateCourse instrdup',
            @category_id=@category, @price=100.00,
            @Modules=@Modules, @Lessons=@Lessons, @CoInstructors=@Co,
            @Prerequisites=@Prereq, @new_course_id=@new_id OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Rechaza instructor repetido en la lista','mas de una vez',@err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_create_course_prereqdup
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @instructor INT = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');
    DECLARE @category   INT = (SELECT id FROM categories WHERE name = 'Categoria Test');
    DECLARE @prereq_id  INT = (SELECT id FROM courses WHERE code = 'EDU-TEST-EXISTING');
    DECLARE @new_id INT, @err VARCHAR(2048) = NULL;

    DECLARE @Modules dbo.ModuleTableType;
    INSERT INTO @Modules (order_index,title,description) VALUES (1,'M1','a'),(2,'M2','b'),(3,'M3','c');
    DECLARE @Lessons dbo.LessonTableType;
    INSERT INTO @Lessons (module_order_index,order_index,title,type,content_url,duration_min) VALUES
        (1,1,'L','video','http://c/1',10),(2,1,'L','video','http://c/2',10),(3,1,'L','video','http://c/3',10);
    DECLARE @Co dbo.CoInstructorTableType;
    INSERT INTO @Co (instructor_id,share_percent,is_main) VALUES (@instructor,100.00,1);
    DECLARE @Prereq dbo.PrerequisiteTableType;
    INSERT INTO @Prereq (prerequisite_course_id) VALUES (@prereq_id),(@prereq_id);

    BEGIN TRY
        EXEC dbo.sp_CreateCourse
            @instructor_id=@instructor, @title='TEST CreateCourse prereqdup',
            @category_id=@category, @price=100.00,
            @Modules=@Modules, @Lessons=@Lessons, @CoInstructors=@Co,
            @Prerequisites=@Prereq, @new_course_id=@new_id OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Rechaza prerequisito repetido','mas de una vez',@err;
END;

-- EJECUTAR TODOS LOS CASOS
PRINT 'PRUEBAS FUNCIONALES: sp_CreateCourse';

EXEC dbo.test_cleanup_created_courses;
EXEC dbo.test_case_create_course_ok;
EXEC dbo.test_case_create_course_2mods;
EXEC dbo.test_case_create_course_share90;
EXEC dbo.test_case_create_course_precio;
EXEC dbo.test_case_create_course_huecomod;
EXEC dbo.test_case_create_course_sincontenido;
EXEC dbo.test_case_create_course_tipomalo;
EXEC dbo.test_case_create_course_2main;
EXEC dbo.test_case_create_course_prereqmalo;
EXEC dbo.test_case_create_course_precionull;
EXEC dbo.test_case_create_course_instrdup;
EXEC dbo.test_case_create_course_prereqdup;
EXEC dbo.test_cleanup_created_courses;

PRINT '';
PRINT 'Fin de pruebas de sp_CreateCourse.';