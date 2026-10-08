
-- sp_TopUpWallet
-- Acredita saldo a la billetera virtual de un usuario (recarga). El cobro real
-- por pasarela de pago queda fuera de la capa de base de datos; este SP
-- registra su resultado. Si el usuario aun no tiene billetera, se crea.
--
-- Cada recarga deja un movimiento 'credit' / 'adjustment' en wallet_movements
-- con el saldo resultante, igual que el resto de operaciones de billetera.
--
-- Concurrencia: dos recargas simultaneas del mismo usuario sin billetera
-- podrian intentar crearla a la vez. UPDLOCK + HOLDLOCK cierra la ventana
-- entre la comprobacion y el INSERT (mismo patron que course_code_sequences).
-- El incremento del saldo se hace con un UPDATE atomico (balance = balance + x),
-- nunca leyendo el saldo y escribiendolo despues.

CREATE OR ALTER PROCEDURE dbo.sp_TopUpWallet
    @user_id     INT,
    @amount      DECIMAL(12,2),
    @new_balance DECIMAL(12,2) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM users WHERE id = @user_id AND active = 1)
        THROW 59001, 'El usuario no existe o no esta activo.', 1;

    IF @amount IS NULL OR @amount <= 0
        THROW 59002, 'El monto de la recarga debe ser mayor a cero.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO wallets (user_id, balance, version)
        SELECT @user_id, 0, 0
        WHERE NOT EXISTS (
            SELECT 1 FROM wallets WITH (UPDLOCK, HOLDLOCK) WHERE user_id = @user_id
        );

        DECLARE @wallet_id INT;
        UPDATE wallets
            SET balance      = balance + @amount,
                version      = version + 1,
                @wallet_id   = id,
                @new_balance = balance + @amount
        WHERE user_id = @user_id;

        INSERT INTO wallet_movements (wallet_id, type, concept, amount, created_at, resulting_balance)
        VALUES (@wallet_id, 'credit', 'adjustment', @amount, GETDATE(), @new_balance);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
