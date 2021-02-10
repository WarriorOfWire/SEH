
-- Data type alias for readability
create domain sequential_exponential_histogram as jsonb;

-- Shared function to glob up a sequential_exponential_histogram from a number column
CREATE OR REPLACE FUNCTION sequential_exponential_histogram_accumulate(internal_state sequential_exponential_histogram, next_row double precision) RETURNS sequential_exponential_histogram
AS $fn$
DECLARE
    bucket text;
    floor_log numeric;
BEGIN
    IF next_row = 0
        THEN bucket := '0';
        ELSE
            floor_log := POW(10, FLOOR(LOG(10, next_row::numeric)));
            bucket := (CEIL(next_row * 2 / floor_log) / 2 * floor_log)::text;
    END IF;
    IF internal_state ? bucket
        THEN internal_state := jsonb_set( internal_state, ARRAY[bucket], to_jsonb((internal_state->bucket)::bigint + 1) );
        ELSE internal_state := jsonb_insert( internal_state, ARRAY[bucket], to_jsonb(1) );
    END IF;
    return internal_state;
END;
$fn$ LANGUAGE plpgsql STRICT IMMUTABLE PARALLEL SAFE;

-- Shared function to combine sequential_exponential_histograms
CREATE OR REPLACE FUNCTION sequential_exponential_histogram_combine(internal_state sequential_exponential_histogram, next_row sequential_exponential_histogram) RETURNS sequential_exponential_histogram
AS $fn$
DECLARE
    _key   text;
    _value bigint;
BEGIN
    FOR _key, _value IN SELECT * from jsonb_each_text(next_row) LOOP
        IF internal_state ? _key
            THEN internal_state := jsonb_set( internal_state, ARRAY[_key], to_jsonb((internal_state->_key)::bigint + _value) );
            ELSE internal_state := jsonb_insert( internal_state, ARRAY[_key], to_jsonb(_value) );
        END IF;
    END LOOP;
    return internal_state;
END;
$fn$ LANGUAGE plpgsql STRICT IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION sequential_exponential_histogram_combine_inv(internal_state sequential_exponential_histogram, next_row sequential_exponential_histogram) RETURNS sequential_exponential_histogram
AS $fn$
DECLARE
    _key   text;
    _value bigint;
BEGIN
    FOR _key, _value IN SELECT * from jsonb_each_text(next_row) LOOP 
        IF internal_state->_key = _value
            THEN internal_state := internal_state - _key;
            ELSE internal_state := jsonb_set( internal_state, ARRAY[_key], to_jsonb((internal_state->_key)::bigint - _value) );
        END IF;
    END LOOP;
    raise notice 'i invertesd';
    return internal_state;
END;
$fn$ LANGUAGE plpgsql STRICT IMMUTABLE PARALLEL SAFE;


-- For downsampling a numeric row into a histogram
CREATE OR REPLACE AGGREGATE accumulate_seh(double precision)
(
    sfunc = sequential_exponential_histogram_accumulate,
    stype = sequential_exponential_histogram,
    initcond = '{}',
    combinefunc = sequential_exponential_histogram_combine,
    PARALLEL = SAFE
);

-- For dynamically combining histograms for presentation
CREATE OR REPLACE AGGREGATE accumulate_seh(sequential_exponential_histogram)
(
    sfunc = sequential_exponential_histogram_combine,
    stype = sequential_exponential_histogram,
    mstype = sequential_exponential_histogram,
    msfunc = sequential_exponential_histogram_combine,
    minvfunc = sequential_exponential_histogram_combine_inv,
    initcond = '{}',
    combinefunc = sequential_exponential_histogram_combine,
    PARALLEL = SAFE
);


-- Pivots a sequential_exponential_histogram out to rows of | bucket int | count text | for convenient graphing in Grafana.
-- Used in Grafana like:
-- select
--   time_bucket('1m', time) as time,
--   (buckets(accumulate_seh(some_column))).*  -- Can be numeric or a pre-downsampled SEH column
-- from metrics_table
-- group by 1 order by 1;
CREATE OR REPLACE FUNCTION buckets( seh sequential_exponential_histogram ) RETURNS TABLE(bucket bigint, count bigint)
AS $$
    select (a.each).key::bigint as bucket, (a.each).value::bigint as count from (select jsonb_each(seh) as each) a;
$$ LANGUAGE SQL STRICT IMMUTABLE PARALLEL SAFE;


