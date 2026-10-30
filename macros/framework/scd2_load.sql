{#- SCD TYPE 2 FRAMEWORK 
    source_model : ref() of the staging model
    business_key : columns that identify a record (include source_system)
    tracked_cols : columns whose change creates a new version
    change_ts    : column holding when the record changed in the source -#}
{% macro scd2_load(source_model, business_key, tracked_cols, change_ts) %}

with incoming as (                                  -- 1. new rows + hash keys
    select
        *,
        {{ fw_hash(business_key) }}  as hash_key,
        {{ fw_hash(tracked_cols) }}  as hash_diff,
        {{ change_ts }}              as valid_from,
        {{ fw_audit_columns() }}
    from {{ source_model }}
    {% if is_incremental() %}
    where {{ change_ts }} > (select max(valid_from) from {{ this }})
    {% endif %}
    qualify row_number() over (                    -- one row per key per timestamp
        partition by {{ fw_hash(business_key) }}, {{ change_ts }}
        order by {{ change_ts }}
    ) = 1
),

{% if is_incremental() %}
current_rows as (                                   -- 2. active versions already loaded
    select * exclude (valid_to, is_current, scd_id)
    from {{ this }}
    where is_current = 'Y'
),
all_rows as (
    select * from current_rows
    union all
    select * from incoming
),
{% else %}
all_rows as (select * from incoming),             -- first run: everything is new
{% endif %}

changes_only as (                                   -- 3. drop rows with no real change
    select *
    from all_rows
    qualify hash_diff is distinct from
            lag(hash_diff) over (partition by hash_key order by valid_from)
),

versioned as (                                      -- 4. each version ends where the next starts
    select
        *,
        lead(valid_from) over (partition by hash_key order by valid_from) as next_from
    from changes_only
)

select                                              -- 5. final SCD2 columns
    * exclude (next_from),
    coalesce(next_from, '{{ var("fw_high_date") }}'::timestamp_ntz) as valid_to,
    iff(next_from is null, 'Y', 'N')                                as is_current,
    {{ fw_hash(['hash_key', 'valid_from']) }}                      as scd_id
from versioned

{% endmacro %}