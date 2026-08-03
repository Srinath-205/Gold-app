import 'package:flutter_test/flutter_test.dart';
import 'package:psm_jewellers_app/main.dart';

void main() {
  testWidgets('shows PSM login after splash', (WidgetTester tester) async {
    await tester.pumpWidget(const PsmApp());
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpAndSettle();

    expect(find.text('P S M Jewellers'), findsWidgets);
    expect(find.text('Sign in to your jewellery workspace'), findsOneWidget);
  });
}
