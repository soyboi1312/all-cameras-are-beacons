#pragma once

// Model the dual-core S3 the shipping envs build for (alerts.cpp pins to portNUM_PROCESSORS - 1:
// core 1 there, 0 on the single-core C5).
#ifndef portNUM_PROCESSORS
#define portNUM_PROCESSORS 2
#endif

#include <stdint.h>

typedef int BaseType_t;
typedef unsigned int UBaseType_t;
typedef uint32_t TickType_t;

#define pdTRUE 1
#define pdFALSE 0
#define portMAX_DELAY ((TickType_t)0xFFFFFFFFu)
#define pdMS_TO_TICKS(ms) ((TickType_t)(ms))
