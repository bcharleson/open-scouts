-- Stagger scout dispatches and reduce timeouts to avoid Firecrawl rate limits (6 req/min)
--
-- Changes:
-- 1. dispatch_due_scouts: Wait 60 seconds between each scout dispatch
-- 2. cleanup_scout_executions: Reduce timeout from 15 to 10 minutes (agent now has 7 loops max)

CREATE OR REPLACE FUNCTION dispatch_due_scouts()
RETURNS void AS $$
DECLARE
  scout_record RECORD;
  supabase_url TEXT;
  anon_key TEXT;
  request_id BIGINT;
  scouts_dispatched INT := 0;
  has_running_execution BOOLEAN;
BEGIN
  SELECT decrypted_secret INTO supabase_url
  FROM vault.decrypted_secrets WHERE name = 'project_url';

  SELECT decrypted_secret INTO anon_key
  FROM vault.decrypted_secrets WHERE name = 'service_role_key';

  IF supabase_url IS NULL OR anon_key IS NULL THEN
    RAISE WARNING 'Vault secrets not configured for dispatcher';
    RETURN;
  END IF;

  FOR scout_record IN
    SELECT id, title FROM scouts
    WHERE should_run_scout(frequency, last_run_at, is_active, title, goal, description, location, search_queries)
    LIMIT 20
  LOOP
    -- Check if this scout already has a running execution
    SELECT EXISTS(
      SELECT 1 FROM scout_executions
      WHERE scout_id = scout_record.id AND status = 'running'
    ) INTO has_running_execution;

    IF has_running_execution THEN
      RAISE NOTICE 'Skipping scout % - already has running execution', scout_record.title;
      CONTINUE;
    END IF;

    -- Wait 60 seconds between dispatches to avoid Firecrawl rate limits (6 req/min)
    -- Skip delay for the first scout to start immediately
    IF scouts_dispatched > 0 THEN
      PERFORM pg_sleep(60);
    END IF;

    SELECT net.http_post(
      url := supabase_url || '/functions/v1/scout-cron?scoutId=' || scout_record.id,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || anon_key
      ),
      body := jsonb_build_object('scoutId', scout_record.id)
    ) INTO request_id;

    RAISE NOTICE 'Dispatched scout % (%/%)', scout_record.title, scouts_dispatched + 1, 20;
    scouts_dispatched := scouts_dispatched + 1;
  END LOOP;

  IF scouts_dispatched > 0 THEN
    RAISE NOTICE 'Dispatched % scouts', scouts_dispatched;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Update cleanup function with reduced timeout (7 loops * 60s = ~7 min, using 10 min as safe bound)
CREATE OR REPLACE FUNCTION cleanup_scout_executions()
RETURNS void AS $$
DECLARE
  stuck_count INT;
BEGIN
  -- Mark executions as failed if running for more than 10 minutes
  -- (Agent can have up to 7 loops with 60s timeouts each, so 10 min is a safe upper bound)
  UPDATE scout_executions
  SET status = 'failed', completed_at = NOW(), error_message = 'Execution timed out after 10 minutes'
  WHERE status = 'running' AND started_at < NOW() - INTERVAL '10 minutes';

  GET DIAGNOSTICS stuck_count = ROW_COUNT;

  IF stuck_count > 0 THEN
    RAISE NOTICE 'Marked % stuck executions as failed', stuck_count;
  END IF;

  DELETE FROM cron.job_run_details WHERE end_time < NOW() - INTERVAL '24 hours';
END;
$$ LANGUAGE plpgsql;
