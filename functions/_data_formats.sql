CREATE OR REPLACE FUNCTION pgr._data_formats()
    RETURNS INTEGER[]
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
AS
$function$
    -- DESCRIPTION: Data formats of a delivery (loine_delivery.data_format) these functions can read.
    --              The data format changes with the tables, columns or meaning of the delivered data; the Loine
    --              version changes with the functions. Deliveries without data_format have format 1.
    --              scripts/build_release.sh writes this list to the file DATA_FORMATS of the release.
SELECT ARRAY[1]::INTEGER[];
$function$;
