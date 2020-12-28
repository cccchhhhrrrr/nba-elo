USE xtdb10001960;

SET FOREIGN_KEY_CHECKS = 0;

-- Base tables:
DROP TABLE IF EXISTS tbl_Players;
CREATE TABLE tbl_Players (
	 PlayerID		INT 	AUTO_INCREMENT
	,PlayerName		VARCHAR(200)
	,IsActive		TINYINT
	,Timestamp		DATETIME
	,PRIMARY KEY(PlayerID)
);

DROP TABLE IF EXISTS tbl_PlayerRatings;
CREATE TABLE tbl_PlayerRatings (
	 RatingID		INT 	AUTO_INCREMENT
	,PlayerID		INT 
	,Rating			DECIMAL(7,2)
	,Timestamp		DATETIME
	,PRIMARY KEY(RatingID)
	,FOREIGN KEY(PlayerID) REFERENCES tbl_Players(PlayerID)
);	

DROP TABLE IF EXISTS tbl_Games;
CREATE TABLE tbl_Games (
	 GameID					INT 	AUTO_INCREMENT
	,UniqueCombination		VARCHAR(10)
	,ParticipationComplete	TINYINT
	,Result					TINYINT
	,Timestamp				DATETIME
	,PRIMARY KEY(GameID)
);

DROP TABLE IF EXISTS tbl_GameParticipations;
CREATE TABLE tbl_GameParticipations (
	 GameParticipationID	INT 	AUTO_INCREMENT
	,GameID					INT
	,PlayerID				INT
	,ParticipationNo		TINYINT
	,RatingBeforeGame		DECIMAL(7,2)
	,ProbabilityOfWinning	DECIMAL(7,2)
	,Result					INT
	,PRIMARY KEY(GameParticipationID)
	,FOREIGN KEY(GameID) REFERENCES tbl_Games(GameID)
	,FOREIGN KEY(PlayerID) REFERENCES tbl_Players(PlayerID)
);


-- Trigger to set initial rating:
DROP TRIGGER IF EXISTS trigger_InitialRating;
DELIMITER //
CREATE TRIGGER trigger_InitialRating
AFTER INSERT ON tbl_Players FOR EACH ROW
	INSERT INTO tbl_PlayerRatings (PlayerID, Rating, Timestamp)
	SELECT PlayerID, 1000.000 AS Rating, Timestamp
	FROM tbl_Players
	WHERE PlayerID NOT IN (SELECT PlayerID FROM tbl_PlayerRatings);
//
DELIMITER ;


-- Function to get current ratings:
DROP FUNCTION IF EXISTS fn_GetCurrentRating;
DELIMITER //
CREATE FUNCTION fn_GetCurrentRating
	(var_PlayerID INT)
RETURNS DECIMAL(7,2)
BEGIN
	DECLARE var_ReturnValue DECIMAL(7,2);
	SET var_ReturnValue = (SELECT Rating FROM tbl_PlayerRatings WHERE PlayerID = var_PlayerID ORDER BY Timestamp DESC LIMIT 1);
	RETURN var_ReturnValue;
END;
//
DELIMITER ;


-- Function to calculate probability of winning:
DROP FUNCTION IF EXISTS fn_ProbabilityOfWinning;
DELIMITER //
CREATE FUNCTION fn_ProbabilityOfWinning
	(var_RatingPlayer DECIMAL(7,2)
	,var_RatingOpponent	DECIMAL(7,2))
RETURNS DECIMAL(7,2)
BEGIN
	DECLARE var_ReturnValue DECIMAL(7,2);
	SET var_ReturnValue = 1.000 / (1.000 + POWER(10.000, (var_RatingOpponent - var_RatingPlayer)/400.000));
	RETURN var_ReturnValue;
END;
//
DELIMITER ;


-- Function to calculate new rating after a game:
DROP FUNCTION IF EXISTS fn_CalculateNewRating;
DELIMITER //
CREATE FUNCTION fn_CalculateNewRating
	(var_OldRating DECIMAL(7,2)
	,var_Result	INT
	,var_ProbabilityOfWinning DECIMAL(7,2))
RETURNS DECIMAL(7,2)
BEGIN
	DECLARE var_ReturnValue DECIMAL(7,2);
	SET var_ReturnValue = var_OldRating + 32.000 * (var_Result - var_ProbabilityOfWinning);
	RETURN var_ReturnValue;
END;
//
DELIMITER ;


-- Procedure to prepare a matchup:
DROP PROCEDURE IF EXISTS sp_PrepareMatchup; 
DELIMITER //
CREATE PROCEDURE sp_PrepareMatchup (
	 IN var_PlayerID1 INT
	,IN var_PlayerID2 INT
)
BEGIN
	DECLARE var_UniqueCombination VARCHAR(10);
	DECLARE var_CurrentGameID INT;
	
	SET var_UniqueCombination = CONCAT(var_PlayerID1, '-', var_PlayerID2);

	INSERT INTO tbl_Games (UniqueCombination, ParticipationComplete) VALUES (var_UniqueCombination, 0);
	
	SET var_CurrentGameID = (SELECT MAX(GameID) FROM tbl_Games WHERE ParticipationComplete = 0);
	
	INSERT INTO tbl_GameParticipations (PlayerID, GameID, ParticipationNo) VALUES
		 (var_PlayerID1, var_CurrentGameID, 1)
		,(var_PlayerID2, var_CurrentGameID, 2);

	UPDATE tbl_Games
	SET ParticipationComplete = 1
	WHERE GameID = var_CurrentGameID;
END;
//
DELIMITER ;


-- View to see active players and their ranks:
CREATE OR REPLACE VIEW view_InnerActivePlayers
AS
	SELECT 
		 *
		,(SELECT Rating 
		  FROM tbl_PlayerRatings pr 
		  WHERE pr.PlayerID = p.PlayerID 
		  ORDER BY pr.Timestamp DESC
		  LIMIT 1) 
		  AS CurrentRating
		,(SELECT COUNT(*) 
		  FROM tbl_GameParticipations gp
		  INNER JOIN tbl_Games g ON g.GameID = gp.GameID
		  WHERE g.Result IS NULL AND gp.PlayerID = p.PlayerID)
		  AS PendingGames
	FROM tbl_Players p;

CREATE OR REPLACE VIEW view_ActivePlayersWithRanks
AS
SELECT 
	 PlayerID
	,PlayerName
	,Timestamp
	,CurrentRating
	,PendingGames
	,UUID() AS RandomString
FROM view_InnerActivePlayers
WHERE IsActive = 1
ORDER BY CurrentRating DESC; 

-- Procedure to create all relevant matchups:
-- Matchups are relevant if:
	-- A player in question does not have too many pending matchups:
		-- 3 pending matchups 	
		-- //TODO
			-- 1st quartile: 10 pending matchups
			-- 2nd quartile: 7 pending matchups
			-- 3rd quartile: 4 pending matchups
			-- 4th quartile: 2 pending matchups
	-- The new matchup does not already exist
	-- The absolute difference in rating between players in question is no more than 150

DROP PROCEDURE IF EXISTS sp_IdentifyAndCreateGames;
DELIMITER //
CREATE PROCEDURE sp_IdentifyAndCreateGames()
BEGIN
	DECLARE var_Counter INT;
	DECLARE var_CreatePlayer1 INT;
	DECLARE var_CreatePlayer2 INT;

	SET var_Counter = 1;
	
	WHILE var_Counter > 0 DO
		DROP TABLE IF EXISTS RelevantGame;
		CREATE TEMPORARY TABLE RelevantGame (
			 PlayerID1 	INT
			,PlayerID2 	INT
		);
		INSERT INTO RelevantGame (PlayerID1, PlayerID2)
		SELECT p1.PlayerID AS PlayerID1, p2.PlayerID AS PlayerID2
		FROM view_ActivePlayersWithRanks p1
		CROSS JOIN view_ActivePlayersWithRanks p2
		WHERE 1 = 1
			AND p1.PlayerID != p2.PlayerID
			AND p2.PlayerID > p1.PlayerID
			AND ABS(p1.CurrentRating - p2.CurrentRating) <= 150
			AND p1.PendingGames < 3
			AND p2.PendingGames < 3
			AND CONCAT(p1.PlayerID,'-',p2.PlayerID) NOT IN (SELECT UniqueCombination FROM tbl_Games WHERE Result IS NULL)
		ORDER BY p1.RandomString DESC;

		SET var_Counter = (SELECT COUNT(*) FROM RelevantGame);
		IF var_Counter <> 0 THEN
			SET var_CreatePlayer1 = (SELECT MAX(PlayerID1) FROM RelevantGame);
			SET var_CreatePlayer2 = (SELECT MAX(PlayerID2) FROM RelevantGame);
			CALL sp_PrepareMatchup(var_CreatePlayer1, var_CreatePlayer2);
		END IF;
	END WHILE;
END;
//
DELIMITER ;

-- Procedure to post results
DROP PROCEDURE IF EXISTS sp_PostResult;
DELIMITER //
CREATE PROCEDURE sp_PostResult(
	 IN var_GameID INT
	,IN var_Result INT
)
BEGIN
	DECLARE var_Player1 INT;
	DECLARE var_Player2 INT;
	DECLARE var_Player1CurrentRating DECIMAL(7,2);
	DECLARE var_Player2CurrentRating DECIMAL(7,2);
	DECLARE var_Player1ProbabilityOfWinning DECIMAL(7,2);
	DECLARE var_Player2ProbabilityOfWinning DECIMAL(7,2);

	SET var_Player1 = (SELECT PlayerID FROM tbl_GameParticipations WHERE GameID = var_GameID AND ParticipationNo = 1);
	SET var_Player2 = (SELECT PlayerID FROM tbl_GameParticipations WHERE GameID = var_GameID AND ParticipationNo = 2);
	SET var_Player1CurrentRating = (SELECT CurrentRating FROM view_ActivePlayersWithRanks WHERE PlayerID = var_Player1);
	SET var_Player2CurrentRating = (SELECT CurrentRating FROM view_ActivePlayersWithRanks WHERE PlayerID = var_Player2);
	SET var_Player1ProbabilityOfWinning = (SELECT fn_ProbabilityOfWinning(var_Player1CurrentRating, var_Player2CurrentRating));
	SET var_Player2ProbabilityOfWinning = (SELECT fn_ProbabilityOfWinning(var_Player2CurrentRating, var_Player1CurrentRating));

	UPDATE tbl_GameParticipations
	SET RatingBeforeGame = var_Player1CurrentRating, ProbabilityOfWinning = var_Player1ProbabilityOfWinning, Result = IF(var_Result = 1, 1, 0)
	WHERE GameID = var_GameID AND PlayerID = var_Player1;

	UPDATE tbl_GameParticipations
	SET RatingBeforeGame = var_Player2CurrentRating, ProbabilityOfWinning = var_Player2ProbabilityOfWinning, Result = IF(var_Result = 2, 1, 0)
	WHERE GameID = var_GameID AND PlayerID = var_Player2;

	UPDATE tbl_Games
	SET Result = var_Result
	WHERE GameID = var_GameID;
	INSERT INTO tbl_PlayerRatings (PlayerID, Rating, Timestamp)
	SELECT
		 gp.PlayerID
		,fn_CalculateNewRating(gp.RatingBeforeGame, gp.Result, gp.ProbabilityOfWinning) AS Rating
		,NOW() AS Timestamp
	FROM tbl_GameParticipations gp
	WHERE GameID = var_GameID;

	IF (SELECT COUNT(*) FROM tbl_Games WHERE Result IS NULL) < 50 THEN
		CALL sp_IdentifyAndCreateGames();
	END IF;
END;
//
DELIMITER ;


-- Procedure to get next pending matchup:
DROP PROCEDURE IF EXISTS sp_GetNextMatchup;
DELIMITER //
CREATE PROCEDURE sp_GetNextMatchup()
BEGIN
	

	DECLARE var_Player1 INT;
	DECLARE var_Player2 INT;
	DECLARE var_Player1CurrentRating DECIMAL(7,2);
	DECLARE var_Player2CurrentRating DECIMAL(7,2);
	DECLARE var_Player1ProbabilityOfWinning DECIMAL(7,2);
	DECLARE var_Player2ProbabilityOfWinning DECIMAL(7,2);

	SET var_Player1 = (SELECT PlayerID FROM tbl_GameParticipations WHERE GameID = var_GameID AND ParticipationNo = 1);
	SET var_Player2 = (SELECT PlayerID FROM tbl_GameParticipations WHERE GameID = var_GameID AND ParticipationNo = 2);
	SET var_Player1CurrentRating = (SELECT CurrentRating FROM view_ActivePlayersWithRanks WHERE PlayerID = var_Player1);
	SET var_Player2CurrentRating = (SELECT CurrentRating FROM view_ActivePlayersWithRanks WHERE PlayerID = var_Player2);
	SET var_Player1ProbabilityOfWinning = (SELECT fn_ProbabilityOfWinning(var_Player1CurrentRating, var_Player2CurrentRating));
	SET var_Player2ProbabilityOfWinning = (SELECT fn_ProbabilityOfWinning(var_Player2CurrentRating, var_Player1CurrentRating));

	UPDATE tbl_GameParticipations
	SET RatingBeforeGame = var_Player1CurrentRating, ProbabilityOfWinning = var_Player1ProbabilityOfWinning, Result = IF(var_Result = 1, 1, 0)
	WHERE GameID = var_GameID AND PlayerID = var_Player1;

	UPDATE tbl_GameParticipations
	SET RatingBeforeGame = var_Player2CurrentRating, ProbabilityOfWinning = var_Player2ProbabilityOfWinning, Result = IF(var_Result = 2, 1, 0)
	WHERE GameID = var_GameID AND PlayerID = var_Player2;

	UPDATE tbl_Games
	SET Result = var_Result, Timestamp = NOW()
	WHERE GameID = var_GameID;

	INSERT INTO tbl_PlayerRatings (PlayerID, Rating, Timestamp)
	SELECT
		 gp.PlayerID
		,fn_CalculateNewRating(gp.RatingBeforeGame, gp.Result, gp.ProbabilityOfWinning) AS Rating
		,NOW() AS Timestamp
	FROM tbl_GameParticipations gp
	WHERE GameID = var_GameID;

	IF (SELECT COUNT(*) FROM tbl_Games WHERE Result IS NULL) < 50 THEN
		CALL sp_IdentifyAndCreateGames();
	END IF;
END;
//
DELIMITER ;

SET FOREIGN_KEY_CHECKS = 1;
