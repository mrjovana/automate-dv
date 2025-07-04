/*
 * Copyright (c) Business Thinking Ltd. 2019-2025
 * This software includes code developed by the AutomateDV (f.k.a dbtvault) Team at Business Thinking Ltd. Trading as Datavault
 */

{%- macro sat(src_pk, src_hashdiff, src_payload, src_extra_columns, src_eff, src_ldts, src_source, source_model) -%}

    {{- automate_dv.check_required_parameters(src_pk=src_pk, src_hashdiff=src_hashdiff, src_payload=src_payload,
                                              src_ldts=src_ldts, src_source=src_source,
                                              source_model=source_model) -}}

    {%- set src_payload = automate_dv.process_payload_column_excludes(
                              src_pk=src_pk, src_hashdiff=src_hashdiff,
                              src_payload=src_payload, src_extra_columns=src_extra_columns, src_eff=src_eff,
                              src_ldts=src_ldts, src_source=src_source, source_model=source_model) -%}

    {{ automate_dv.prepend_generated_by() }}

    {{ adapter.dispatch('sat', 'automate_dv')(src_pk=src_pk, src_hashdiff=src_hashdiff,
                                              src_payload=src_payload, src_extra_columns=src_extra_columns,
                                              src_eff=src_eff, src_ldts=src_ldts,
                                              src_source=src_source, source_model=source_model) -}}

{%- endmacro -%}

{%- macro default__sat(src_pk, src_hashdiff, src_payload, src_extra_columns, src_eff, src_ldts, src_source, source_model) -%}

{%- set apply_source_filter = config.get('apply_source_filter', false) -%}
{%- set enable_ghost_record = var('enable_ghost_records', false) %}

{%- set source_cols = automate_dv.expand_column_list(columns=[src_pk, src_hashdiff, src_payload, src_extra_columns, src_eff, src_ldts, src_source]) -%}
{%- set window_cols = automate_dv.expand_column_list(columns=[src_pk, src_hashdiff, src_ldts, src_eff]) -%}
{%- set pk_cols = automate_dv.expand_column_list(columns=[src_pk]) -%}

{%- if model.config.materialized == 'vault_insert_by_rank' %}
    {%- set source_cols_with_rank = source_cols + [config.get('rank_column')] -%}
{%- endif %}

WITH source_data AS (
    {%- if model.config.materialized == 'vault_insert_by_rank' %}
    SELECT {{ automate_dv.prefix(source_cols_with_rank, 'a', alias_target='source') }}
    {%- else %}
    SELECT {{ automate_dv.prefix(source_cols, 'a', alias_target='source') }}
    {%- endif %}
    FROM {{ ref(source_model) }} AS a
    WHERE {{ automate_dv.multikey(src_pk, prefix='a', condition='IS NOT NULL') }}
    {%- if model.config.materialized == 'vault_insert_by_period' %}
    AND __PERIOD_FILTER__
    {% elif model.config.materialized == 'vault_insert_by_rank' %}
    AND __RANK_FILTER__
    {% endif %}
),

{%- if automate_dv.is_any_incremental() %}

latest_records AS (
    SELECT {{ automate_dv.prefix(window_cols, 'current_records', alias_target='target') }}
    FROM {{ this }} AS current_records
    JOIN (
        SELECT DISTINCT {{ automate_dv.prefix([src_pk], 'source_data') }}
        FROM source_data
    ) AS source_records
        ON {{ automate_dv.multikey(src_pk, prefix=['source_records','current_records'], condition='=') }}
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY {{ automate_dv.prefix([src_pk], 'current_records') }}
        ORDER BY {{ automate_dv.prefix([src_ldts], 'current_records') }} DESC
        {%- if automate_dv.is_something(src_eff) -%}
        , {{ automate_dv.prefix([src_eff], 'current_records') }} DESC
        {%- endif %}
    ) = 1
),

{%- if apply_source_filter %}

valid_stg AS (
    SELECT {{ automate_dv.prefix(source_cols, 's', alias_target='source') }}
    FROM source_data AS s
    LEFT JOIN latest_records AS sat
        ON {{ automate_dv.multikey(src_pk, prefix=['s', 'sat'], condition='=') }}
        WHERE {{ automate_dv.multikey(src_pk, prefix='sat', condition='IS NULL') }}
        OR {{ automate_dv.prefix([src_ldts], 's') }} > (
            SELECT MAX({{ src_ldts }}) FROM latest_records AS sat
            WHERE {{ automate_dv.multikey(src_pk, prefix=['sat','s'], condition='=') }}
        )
),
{%- endif %}

{%- endif %}

{%- set is_incremental = automate_dv.is_any_incremental() -%}
{%- set use_valid_stg = is_incremental and apply_source_filter -%}
{%- set source_table = 'valid_stg AS sd' if use_valid_stg else 'source_data AS sd' -%}
{%- set hashdiff_alias = automate_dv.prefix([src_hashdiff], 'sd', alias_target='source') -%}
{%- set lag_default = automate_dv.cast_binary('FFFFFFFF', quote=true) -%}
{%- set partition_by = automate_dv.prefix([src_pk], 'sd', alias_target='source') -%}
{%- set is_bigquery = target.type == 'bigquery' -%}
{%- set order_by = automate_dv.prefix([src_ldts], 'sd', alias_target='source') -%}

{%- set use_eff = automate_dv.is_something(src_eff) -%}

{%- if use_eff -%}
    {%- set order_by_eff = automate_dv.prefix([src_eff], 'sd', alias_target='source') -%}
{%- endif -%}

{#- BigQuery does not support a 3-arg LAG() where the third arg is an expression, it must be a constant. Workaround below #}

unique_source_records AS (
    SELECT
        {{ automate_dv.prefix(source_cols, 'sd', alias_target='source') }}
    FROM {{ source_table }}
    {%- if is_incremental %}
    LEFT OUTER JOIN latest_records AS lr
        ON {{ automate_dv.multikey(src_pk, prefix=['sd','lr'], condition='=') }}
    {%- endif %}

    QUALIFY {{ hashdiff_alias }} !=
    {%- if is_incremental and is_bigquery %}
        COALESCE(
            LAG({{ hashdiff_alias }}, 1) OVER (
                PARTITION BY {{ partition_by }}
                {%- if use_eff %}
                ORDER BY {{ order_by }} ASC,
                         {{ order_by_eff }} ASC
                {%- else %}
                ORDER BY {{ order_by }} ASC
                {%- endif %}
            ),
            {{ automate_dv.prefix([src_hashdiff], 'lr', alias_target='target') }},
            {{ lag_default }}
        )
    {%- elif is_incremental and not is_bigquery %}
        LAG({{ hashdiff_alias }}, 1,
            COALESCE(
                {{ automate_dv.prefix([src_hashdiff], 'lr', alias_target='target') }},
                {{ lag_default }}
            )
        ) OVER (
            PARTITION BY {{ partition_by }}
            {%- if use_eff %}
            ORDER BY {{ order_by }} ASC,
                     {{ order_by_eff }} ASC
            {%- else %}
            ORDER BY {{ order_by }} ASC
            {%- endif %}
        )
    {%- else %}
        LAG({{ hashdiff_alias }}, 1, {{ lag_default }}) OVER (
            PARTITION BY {{ partition_by }}
            {%- if use_eff %}
            ORDER BY {{ order_by }} ASC,
                     {{ order_by_eff }} ASC
            {%- else %}
            ORDER BY {{ order_by }} ASC
            {%- endif %}
        )
    {%- endif %}
),

{%- if enable_ghost_record %}

ghost AS (
    {{ automate_dv.create_ghost_record(src_pk=src_pk, src_hashdiff=src_hashdiff,
                                       src_payload=src_payload, src_extra_columns=src_extra_columns,
                                       src_eff=src_eff, src_ldts=src_ldts,
                                       src_source=src_source, source_model=source_model) }}
),

{%- endif %}

records_to_insert AS (
    {%- if enable_ghost_record %}
    SELECT
    {{ automate_dv.alias_all(source_cols, 'g') }}
    FROM ghost AS g
    {%- if automate_dv.is_any_incremental() %}
    WHERE NOT EXISTS ( SELECT 1 FROM {{ this }} AS h WHERE {{ automate_dv.prefix([src_hashdiff], 'h', alias_target='target') }} = {{ automate_dv.prefix([src_hashdiff], 'g') }} )
    {% else %}
    WHERE NOT EXISTS ( SELECT 1 FROM source_data AS h WHERE {{ automate_dv.prefix([src_hashdiff], 'h', alias_target='source') }} = {{ automate_dv.prefix([src_hashdiff], 'g') }} )
    {%- endif %}
    UNION {%- if target.type == 'bigquery' %} DISTINCT {%- endif %}
    {%- endif %}
    SELECT {{ automate_dv.alias_all(source_cols, 'usr') }}
    FROM unique_source_records AS usr
)

SELECT * FROM records_to_insert
{%- endmacro -%}