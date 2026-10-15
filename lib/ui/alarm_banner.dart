import 'package:flutter/material.dart';
import '../logic/domain.dart';
import '../services/trip_controller.dart';

/// Kept outside every page's scroll view so changing tabs or scrolling cannot
/// hide an active camera warning. Rest recommendations retain their own state.
class AlarmBanner extends StatelessWidget {
  const AlarmBanner({super.key, required this.trip});
  final TripController trip;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: trip,
    builder: (context, _) {
      final events = trip.snapshot?.activeEvents ?? [];
      if (events.isEmpty) return const SizedBox.shrink();
      final ids = events.map((e) => e.id).toSet();
      return Container(
        key: const Key('global-alarm'),
        width: double.infinity,
        color: const Color(0xffB3261E),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                events
                    .map(
                      (e) => e.type == EventType.eyesClosed
                          ? 'Длительное закрытие глаз. Остановитесь в безопасном месте для отдыха.'
                          : 'Продолжительный наклон головы — проверьте состояние',
                    )
                    .join('\n'),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (trip.snapshot!.hasUnacknowledgedAlert)
              IconButton(
                onPressed: () => trip.acknowledge(ids),
                tooltip: 'Подтвердить и выключить сигнал',
                icon: const Icon(
                  Icons.volume_off_outlined,
                  color: Colors.white,
                ),
              ),
          ],
        ),
      );
    },
  );
}
