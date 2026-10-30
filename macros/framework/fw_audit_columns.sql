{% macro fw_audit_columns() %}
    current_timestamp()::timestamp_ntz as dw_load_ts,
    '{{ invocation_id }}'               as dw_run_id
{% endmacro %}