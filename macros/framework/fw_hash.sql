{% macro fw_hash(columns) %}
    {{ dbt_utils.generate_surrogate_key(columns) }}
{% endmacro %}